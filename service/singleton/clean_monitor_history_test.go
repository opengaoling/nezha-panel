package singleton

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"github.com/nezhahq/nezha/model"
	"github.com/nezhahq/nezha/pkg/tsdb"
)

func setupCleanMonitorHistoryTest(t *testing.T) func() {
	t.Helper()
	origDB := DB
	origConf := Conf
	origTSDBShared := TSDBShared
	origAlerts := Alerts
	origServerShared := ServerShared
	origCycleLookup := model.CycleTransferLookup

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	if sqlDB, errInner := db.DB(); errInner == nil {
		sqlDB.SetMaxOpenConns(1)
	}

	require.NoError(t, db.AutoMigrate(&model.Server{}, &model.Transfer{}, &model.AlertRule{}))
	DB = db
	ServerShared = NewServerClass()

	if Conf == nil {
		Conf = &model.Config{}
	}
	Conf.TSDB.RetentionDays = 30

	return func() {
		DB = origDB
		Conf = origConf
		TSDBShared = origTSDBShared
		Alerts = origAlerts
		ServerShared = origServerShared
		model.CycleTransferLookup = origCycleLookup
	}
}

func setupTestTSDBForClean(t *testing.T) (*tsdb.TSDB, func()) {
	t.Helper()
	tempDir, err := os.MkdirTemp("", "tsdb_clean_test")
	require.NoError(t, err)
	config := &tsdb.Config{
		DataPath:           filepath.Join(tempDir, "tsdb"),
		RetentionDays:      30,
		MinFreeDiskSpaceGB: 1,
		MaxMemoryMB:        256,
	}
	db, err := tsdb.Open(config)
	require.NoError(t, err)
	return db, func() {
		db.Close()
		os.RemoveAll(tempDir)
	}
}

func TestCleanMonitorHistory_TSDBEnabled_PurgesAllTransfers(t *testing.T) {
	cleanup := setupCleanMonitorHistoryTest(t)
	defer cleanup()

	testTSDB, tsdbCleanup := setupTestTSDBForClean(t)
	defer tsdbCleanup()
	TSDBShared = testTSDB

	require.NoError(t, DB.Create(&model.Server{Common: model.Common{ID: 1}}).Error)
	require.NoError(t, DB.Create(&model.Transfer{ServerID: 1, In: 100, Out: 200, Common: model.Common{CreatedAt: time.Now().Add(-10 * time.Hour)}}).Error)
	require.NoError(t, DB.Create(&model.Transfer{ServerID: 1, In: 300, Out: 400, Common: model.Common{CreatedAt: time.Now().AddDate(0, 0, -40)}}).Error)

	var countBefore int64
	require.NoError(t, DB.Model(&model.Transfer{}).Count(&countBefore).Error)
	require.Equal(t, int64(2), countBefore)

	CleanMonitorHistory()

	var countAfter int64
	require.NoError(t, DB.Model(&model.Transfer{}).Count(&countAfter).Error)
	require.Equal(t, int64(0), countAfter, "all transfers in sqlite should be purged when TSDB is enabled")
}

func TestCleanMonitorHistory_TSDBDisabled_TrimsExpired(t *testing.T) {
	cleanup := setupCleanMonitorHistoryTest(t)
	defer cleanup()
	TSDBShared = nil // TSDB disabled

	require.NoError(t, DB.Create(&model.Server{Common: model.Common{ID: 1}}).Error)
	// 5 days ago (should keep)
	require.NoError(t, DB.Create(&model.Transfer{ServerID: 1, In: 100, Out: 200, Common: model.Common{CreatedAt: time.Now().AddDate(0, 0, -5)}}).Error)
	// 40 days ago (should delete, > 30 days)
	require.NoError(t, DB.Create(&model.Transfer{ServerID: 1, In: 300, Out: 400, Common: model.Common{CreatedAt: time.Now().AddDate(0, 0, -40)}}).Error)

	CleanMonitorHistory()

	var countAfter int64
	require.NoError(t, DB.Model(&model.Transfer{}).Count(&countAfter).Error)
	require.Equal(t, int64(1), countAfter, "only recent transfers (<= 30 days) should remain when TSDB is disabled")
}

func TestCleanMonitorHistory_TSDBDisabled_WithCycleRule_KeepsRuleDuration(t *testing.T) {
	cleanup := setupCleanMonitorHistoryTest(t)
	defer cleanup()
	TSDBShared = nil // TSDB disabled

	cycleStart := time.Now().AddDate(0, 0, -10)
	alert := &model.AlertRule{
		Common: model.Common{ID: 1},
		Name:   "Cycle Alert",
		Rules: []*model.Rule{
			{
				Type:          "transfer_in_cycle",
				Cover:         model.RuleCoverAll,
				CycleStart:    &cycleStart,
				CycleInterval: 1,
				CycleUnit:     "month",
			},
		},
	}
	require.NoError(t, DB.Create(alert).Error)

	require.NoError(t, DB.Create(&model.Server{Common: model.Common{ID: 1}}).Error)
	// 5 days ago (within cycle, keep)
	require.NoError(t, DB.Create(&model.Transfer{ServerID: 1, In: 100, Out: 200, Common: model.Common{CreatedAt: time.Now().AddDate(0, 0, -5)}}).Error)
	// 15 days ago (older than cycle start, delete)
	require.NoError(t, DB.Create(&model.Transfer{ServerID: 1, In: 300, Out: 400, Common: model.Common{CreatedAt: time.Now().AddDate(0, 0, -15)}}).Error)

	CleanMonitorHistory()

	var countAfter int64
	require.NoError(t, DB.Model(&model.Transfer{}).Count(&countAfter).Error)
	require.Equal(t, int64(1), countAfter, "transfers older than cycle start must be deleted when TSDB is disabled")
}

func TestRecordTransferHourlyUsage_SkipsWhenTSDBEnabled(t *testing.T) {
	cleanup := setupCleanMonitorHistoryTest(t)
	defer cleanup()

	testTSDB, tsdbCleanup := setupTestTSDBForClean(t)
	defer tsdbCleanup()
	TSDBShared = testTSDB

	server := &model.Server{
		Common: model.Common{ID: 1},
		State: &model.HostState{
			NetInTransfer:  1000,
			NetOutTransfer: 2000,
		},
	}
	ServerShared.list[1] = server

	RecordTransferHourlyUsage()

	var count int64
	require.NoError(t, DB.Model(&model.Transfer{}).Count(&count).Error)
	require.Equal(t, int64(0), count, "no rows should be inserted to SQLite transfers when TSDB is enabled")
	require.Equal(t, uint64(1000), server.PrevTransferInSnapshot, "in-memory snapshot baseline should still be updated")
	require.Equal(t, uint64(2000), server.PrevTransferOutSnapshot, "in-memory snapshot baseline should still be updated")
}

func TestTSDB_QueryTransferCycle_MonotonicAndReboot(t *testing.T) {
	testTSDB, tsdbCleanup := setupTestTSDBForClean(t)
	defer tsdbCleanup()

	serverID := uint64(42)
	baseTime := time.Now().Add(-2 * time.Hour)

	// 模拟正常单调累积写入
	require.NoError(t, testTSDB.WriteServerMetrics(&tsdb.ServerMetrics{
		ServerID:      serverID,
		Timestamp:     baseTime,
		NetInTransfer: 1000,
	}))
	require.NoError(t, testTSDB.WriteServerMetrics(&tsdb.ServerMetrics{
		ServerID:      serverID,
		Timestamp:     baseTime.Add(30 * time.Minute),
		NetInTransfer: 2500, // +1500
	}))
	// 模拟服务器重启: 计数器重置为 500
	require.NoError(t, testTSDB.WriteServerMetrics(&tsdb.ServerMetrics{
		ServerID:      serverID,
		Timestamp:     baseTime.Add(60 * time.Minute),
		NetInTransfer: 500, // reboot, +500
	}))
	// 重启后继续传输
	require.NoError(t, testTSDB.WriteServerMetrics(&tsdb.ServerMetrics{
		ServerID:      serverID,
		Timestamp:     baseTime.Add(90 * time.Minute),
		NetInTransfer: 1200, // +700
	}))
	testTSDB.Flush()

	// 预期增量: (2500-1000) + 500(重启后增量) + (1200-500) = 1500 + 500 + 700 = 2700
	// 当前内存中最新值为 1500 (又传输了 300)
	cycleStart := baseTime.Add(-5 * time.Minute)
	total, err := testTSDB.QueryTransferCycle(serverID, tsdb.MetricServerNetInTransfer, cycleStart, 1500)
	require.NoError(t, err)
	require.Equal(t, uint64(3000), total, "expected 2700 from points + 300 from current memory state")
}

func TestRuleSnapshot_WithTSDBCycleLookup(t *testing.T) {
	cycleStart := time.Now().Add(-1 * time.Hour)
	rule := &model.Rule{
		Type:          "transfer_in_cycle",
		CycleStart:    &cycleStart,
		CycleInterval: 1,
		CycleUnit:     "hour",
		Max:           10000,
	}

	server := &model.Server{
		Common: model.Common{ID: 99},
		Name:   "TestServer",
		State: &model.HostState{
			NetInTransfer: 5000,
		},
	}

	origLookup := model.CycleTransferLookup
	defer func() { model.CycleTransferLookup = origLookup }()

	// 注册模拟的 TSDB 回调
	model.CycleTransferLookup = func(serverID uint64, metric string, start time.Time, curIn, curOut uint64) (uint64, bool) {
		require.Equal(t, uint64(99), serverID)
		require.Equal(t, "in", metric)
		return 3500, true
	}

	stats := &model.CycleTransferStats{
		ServerName: make(map[uint64]string),
		Transfer:   make(map[uint64]uint64),
		NextUpdate: make(map[uint64]time.Time),
	}

	passed := rule.Snapshot(stats, server, nil)
	require.True(t, passed, "3500 < 10000 should pass")
	require.Equal(t, uint64(3500), stats.Transfer[server.ID], "cycle transfer stats should record 3500 bytes from TSDB")
}
