package setup

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestDecideAdminBootstrap(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		totalUsers int64
		adminUsers int64
		should     bool
		reason     string
	}{
		{
			name:       "empty database should create admin",
			totalUsers: 0,
			adminUsers: 0,
			should:     true,
			reason:     adminBootstrapReasonEmptyDatabase,
		},
		{
			name:       "admin exists should skip",
			totalUsers: 10,
			adminUsers: 1,
			should:     false,
			reason:     adminBootstrapReasonAdminExists,
		},
		{
			name:       "users exist without admin should skip",
			totalUsers: 5,
			adminUsers: 0,
			should:     false,
			reason:     adminBootstrapReasonUsersExistWithoutAdmin,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := decideAdminBootstrap(tc.totalUsers, tc.adminUsers)
			if got.shouldCreate != tc.should {
				t.Fatalf("shouldCreate=%v, want %v", got.shouldCreate, tc.should)
			}
			if got.reason != tc.reason {
				t.Fatalf("reason=%q, want %q", got.reason, tc.reason)
			}
		})
	}
}

func TestSetupDefaultAdminConcurrency(t *testing.T) {
	t.Run("simple mode admin uses higher concurrency", func(t *testing.T) {
		t.Setenv("RUN_MODE", "simple")
		if got := setupDefaultAdminConcurrency(); got != simpleModeAdminConcurrency {
			t.Fatalf("setupDefaultAdminConcurrency()=%d, want %d", got, simpleModeAdminConcurrency)
		}
	})

	t.Run("standard mode keeps existing default", func(t *testing.T) {
		t.Setenv("RUN_MODE", "standard")
		if got := setupDefaultAdminConcurrency(); got != defaultUserConcurrency {
			t.Fatalf("setupDefaultAdminConcurrency()=%d, want %d", got, defaultUserConcurrency)
		}
	})
}

func TestWriteConfigFileKeepsDefaultUserConcurrency(t *testing.T) {
	t.Setenv("RUN_MODE", "simple")
	t.Setenv("DATA_DIR", t.TempDir())

	if err := writeConfigFile(&SetupConfig{}); err != nil {
		t.Fatalf("writeConfigFile() error = %v", err)
	}

	data, err := os.ReadFile(GetConfigFilePath())
	if err != nil {
		t.Fatalf("ReadFile() error = %v", err)
	}

	if !strings.Contains(string(data), "user_concurrency: 5") {
		t.Fatalf("config missing default user concurrency, got:\n%s", string(data))
	}
}

func TestSetupMigrationTimeoutFromEnv(t *testing.T) {
	t.Setenv("AUTO_SETUP_MIGRATION_TIMEOUT_SECONDS", "30")

	if got := setupMigrationTimeout(); got != 30*time.Second {
		t.Fatalf("setupMigrationTimeout()=%s, want 30s", got)
	}
}

func TestSetupMigrationTimeoutFallsBackToDefault(t *testing.T) {
	t.Setenv("AUTO_SETUP_MIGRATION_TIMEOUT_SECONDS", "0")

	if got := setupMigrationTimeout(); got != 10*time.Minute {
		t.Fatalf("setupMigrationTimeout()=%s, want 10m0s", got)
	}
}

func TestSetupAdminBootstrapTimeoutFromEnv(t *testing.T) {
	t.Setenv("AUTO_SETUP_ADMIN_TIMEOUT_SECONDS", "45")

	if got := setupAdminBootstrapTimeout(); got != 45*time.Second {
		t.Fatalf("setupAdminBootstrapTimeout()=%s, want 45s", got)
	}
}

func TestSetupAdminBootstrapTimeoutFallsBackToDefault(t *testing.T) {
	t.Setenv("AUTO_SETUP_ADMIN_TIMEOUT_SECONDS", "0")

	if got := setupAdminBootstrapTimeout(); got != 30*time.Second {
		t.Fatalf("setupAdminBootstrapTimeout()=%s, want 30s", got)
	}
}

func TestDatabaseConfigFromEnvUsesDatabaseURL(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgresql://postgres.exampleproject:secret%40value@aws-1-us-west-2.pooler.supabase.com:6543/postgres?sslmode=require")
	t.Setenv("DATABASE_HOST", "ignored")
	t.Setenv("DATABASE_PORT", "1234")
	t.Setenv("DATABASE_USER", "ignored")
	t.Setenv("DATABASE_PASSWORD", "ignored")
	t.Setenv("DATABASE_DBNAME", "ignored")
	t.Setenv("DATABASE_SSLMODE", "disable")

	cfg, err := databaseConfigFromEnv()
	if err != nil {
		t.Fatalf("databaseConfigFromEnv() error = %v", err)
	}

	if cfg.Host != "aws-1-us-west-2.pooler.supabase.com" {
		t.Fatalf("Host=%q", cfg.Host)
	}
	if cfg.Port != 6543 {
		t.Fatalf("Port=%d", cfg.Port)
	}
	if cfg.User != "postgres.exampleproject" {
		t.Fatalf("User=%q", cfg.User)
	}
	if cfg.Password != "secret@value" {
		t.Fatalf("Password=%q", cfg.Password)
	}
	if cfg.DBName != "postgres" {
		t.Fatalf("DBName=%q", cfg.DBName)
	}
	if cfg.SSLMode != "require" {
		t.Fatalf("SSLMode=%q", cfg.SSLMode)
	}
	if !cfg.ExternalDSN {
		t.Fatalf("ExternalDSN=false, want true")
	}
}

func TestDatabaseConfigFromEnvDatabaseURLDefaultsSSLModeToRequire(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://user:pass@example.com:5432/app")

	cfg, err := databaseConfigFromEnv()
	if err != nil {
		t.Fatalf("databaseConfigFromEnv() error = %v", err)
	}

	if cfg.SSLMode != "require" {
		t.Fatalf("SSLMode=%q, want require", cfg.SSLMode)
	}
}

func TestDatabaseConfigFromEnvSplitEnvFallback(t *testing.T) {
	t.Setenv("DATABASE_HOST", "postgres")
	t.Setenv("DATABASE_PORT", "15432")
	t.Setenv("DATABASE_USER", "sub2api")
	t.Setenv("DATABASE_PASSWORD", "password")
	t.Setenv("DATABASE_DBNAME", "sub2api")
	t.Setenv("DATABASE_SSLMODE", "disable")

	cfg, err := databaseConfigFromEnv()
	if err != nil {
		t.Fatalf("databaseConfigFromEnv() error = %v", err)
	}

	if cfg.Host != "postgres" || cfg.Port != 15432 || cfg.User != "sub2api" ||
		cfg.Password != "password" || cfg.DBName != "sub2api" || cfg.SSLMode != "disable" {
		t.Fatalf("unexpected config: %#v", cfg)
	}
	if cfg.ExternalDSN {
		t.Fatalf("ExternalDSN=true, want false")
	}
}

func TestDatabaseDSNIncludesBinaryParameters(t *testing.T) {
	got := databaseDSN(&DatabaseConfig{
		Host:    "example.com",
		Port:    5432,
		User:    "user",
		DBName:  "app",
		SSLMode: "require",
	})

	if !strings.Contains(got, "binary_parameters=yes") {
		t.Fatalf("databaseDSN() missing binary_parameters=yes: %q", got)
	}
	if strings.Contains(got, "password=") {
		t.Fatalf("databaseDSN() should omit empty password: %q", got)
	}
}

func TestRedisConfigFromEnvUsesRedisURL(t *testing.T) {
	t.Setenv("REDIS_URL", "rediss://:secret%40value@cache.example.com:6380/2")
	t.Setenv("REDIS_HOST", "ignored")
	t.Setenv("REDIS_PORT", "1234")
	t.Setenv("REDIS_PASSWORD", "ignored")
	t.Setenv("REDIS_DB", "0")
	t.Setenv("REDIS_ENABLE_TLS", "false")

	cfg, err := redisConfigFromEnv()
	if err != nil {
		t.Fatalf("redisConfigFromEnv() error = %v", err)
	}

	if cfg.Host != "cache.example.com" {
		t.Fatalf("Host=%q", cfg.Host)
	}
	if cfg.Port != 6380 {
		t.Fatalf("Port=%d", cfg.Port)
	}
	if cfg.Password != "secret@value" {
		t.Fatalf("Password=%q", cfg.Password)
	}
	if cfg.DB != 2 {
		t.Fatalf("DB=%d", cfg.DB)
	}
	if !cfg.EnableTLS {
		t.Fatalf("EnableTLS=false, want true")
	}
}

func TestRedisConfigFromEnvSplitEnvFallback(t *testing.T) {
	t.Setenv("REDIS_HOST", "redis")
	t.Setenv("REDIS_PORT", "16379")
	t.Setenv("REDIS_PASSWORD", "password")
	t.Setenv("REDIS_DB", "3")
	t.Setenv("REDIS_ENABLE_TLS", "true")

	cfg, err := redisConfigFromEnv()
	if err != nil {
		t.Fatalf("redisConfigFromEnv() error = %v", err)
	}

	if cfg.Host != "redis" || cfg.Port != 16379 || cfg.Password != "password" ||
		cfg.DB != 3 || !cfg.EnableTLS {
		t.Fatalf("unexpected config: %#v", cfg)
	}
}
