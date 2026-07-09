#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("failed to open database: {0}")]
    Open(#[from] std::io::Error),

    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    #[error("database migration error: {0}")]
    Migration(#[from] rusqlite_migration::Error),

    #[error(
        "database schema version {db_version} is newer than binary schema version {binary_version}"
    )]
    SchemaTooNew {
        db_version: u32,
        binary_version: u32,
    },

    #[error("invalid status for {table}: {value}")]
    InvalidStatus { table: &'static str, value: String },

    #[error("data integrity violation in {table}: {reason}")]
    DataIntegrity {
        table: &'static str,
        reason: &'static str,
    },

    #[error("store actor inbox full")]
    Backpressure,
}
