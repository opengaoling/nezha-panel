package singleton

import (
	"log"
	"time"

	"gorm.io/gorm"

	"github.com/nezhahq/nezha/model"
	"github.com/nezhahq/nezha/pkg/tsdb"
)

var TSDBShared *tsdb.TSDB

func InitTSDB() error {
	config := &tsdb.Config{
		RetentionDays:      30,
		MinFreeDiskSpaceGB: 1,
		MaxMemoryMB:        256,
	}

	if Conf.TSDB.DataPath != "" {
		config.DataPath = Conf.TSDB.DataPath
	}
	if Conf.TSDB.RetentionDays > 0 {
		config.RetentionDays = Conf.TSDB.RetentionDays
	}
	if Conf.TSDB.MinFreeDiskSpaceGB > 0 {
		config.MinFreeDiskSpaceGB = Conf.TSDB.MinFreeDiskSpaceGB
	}
	if Conf.TSDB.MaxMemoryMB > 0 {
		config.MaxMemoryMB = Conf.TSDB.MaxMemoryMB
	}
	if Conf.TSDB.WriteBufferSize > 0 {
		config.WriteBufferSize = Conf.TSDB.WriteBufferSize
	}
	if Conf.TSDB.WriteBufferFlushInterval > 0 {
		config.WriteBufferFlushInterval = time.Duration(Conf.TSDB.WriteBufferFlushInterval) * time.Second
	}

	if !config.Enabled() {
		log.Println("NEZHA>> TSDB is disabled (tsdb.data_path not configured)")
		if DB != nil {
			return DB.AutoMigrate(model.ServiceHistory{})
		}
		return nil
	}

	var err error
	TSDBShared, err = tsdb.Open(config)
	if err != nil {
		return err
	}

	log.Println("NEZHA>> TSDB initialized successfully")

	// 注册基于 TSDB 的周期流量查询回调，周期流量统计直接由 TSDB 计算，不再依赖 SQLite transfers 表
	model.CycleTransferLookup = func(serverID uint64, metric string, cycleStart time.Time, currentNetIn uint64, currentNetOut uint64) (uint64, bool) {
		if !TSDBEnabled() {
			return 0, false
		}
		switch metric {
		case "in":
			val, err := TSDBShared.QueryTransferCycle(serverID, tsdb.MetricServerNetInTransfer, cycleStart, currentNetIn)
			if err != nil {
				return 0, false
			}
			return val, true
		case "out":
			val, err := TSDBShared.QueryTransferCycle(serverID, tsdb.MetricServerNetOutTransfer, cycleStart, currentNetOut)
			if err != nil {
				return 0, false
			}
			return val, true
		case "all":
			inVal, err1 := TSDBShared.QueryTransferCycle(serverID, tsdb.MetricServerNetInTransfer, cycleStart, currentNetIn)
			outVal, err2 := TSDBShared.QueryTransferCycle(serverID, tsdb.MetricServerNetOutTransfer, cycleStart, currentNetOut)
			if err1 != nil && err2 != nil {
				return 0, false
			}
			return inVal + outVal, true
		default:
			return 0, false
		}
	}

	if DB != nil && DB.Migrator().HasTable("service_histories") {
		log.Println("NEZHA>> Dropping legacy service_histories table (TSDB is now enabled). Historical data will NOT be migrated.")
		if err := DB.Migrator().DropTable("service_histories"); err != nil {
			log.Printf("NEZHA>> Warning: failed to drop service_histories table: %v", err)
		}
	}

	// 启用 TSDB 时，流量数据已由 TSDB 托管，清理 SQLite transfers 表中遗留的历史记录并 VACUUM
	if DB != nil {
		var count int64
		if err := DB.Model(&model.Transfer{}).Count(&count).Error; err == nil && count > 0 {
			log.Printf("NEZHA>> TSDB is enabled. Purging %d legacy transfer records from SQLite transfers table...", count)
			DB.Unscoped().Session(&gorm.Session{AllowGlobalUpdate: true}).Delete(&model.Transfer{})
			log.Println("NEZHA>> SQLite: Executing VACUUM to reclaim disk space after transfers purge...")
			if err := DB.Exec("VACUUM").Error; err != nil {
				log.Printf("NEZHA>> SQLite: VACUUM failed: %v", err)
			} else {
				log.Println("NEZHA>> SQLite: VACUUM completed successfully")
			}
		}
	}

	return nil
}

func TSDBEnabled() bool {
	return TSDBShared != nil && !TSDBShared.IsClosed()
}

func CloseTSDB() {
	model.CycleTransferLookup = nil
	if TSDBShared != nil {
		TSDBShared.Close()
	}
}

