
#!/bin/bash

# ============================================================
# ORACLE SQL PLAN BASELINE MIGRATION
# SOURCE DATABASE --> TARGET DATABASE
#
# Requirements:
#   SQL*Plus, EXPDP, IMPDP, SCP, SSH
#   Oracle Wallet configured for both databases
#   SPM privileges
# ============================================================

set -Eeuo pipefail

# ---------------- CONFIGURATION ----------------

SOURCE_CONN="/@SOURCE_DB"
TARGET_CONN="/@TARGET_DB"

SOURCE_SERVER="source-server"
TARGET_SERVER="target-server"

SOURCE_DIR="/u01/spm_migration"
TARGET_DIR="/u01/spm_migration"

DP_DIR="DATA_PUMP_DIR"
DUMP="SPM_MIGRATION.dmp"
STAGE="SPM_STAGING"

LOG="${SOURCE_DIR}/spm_migration_$(date +%Y%m%d_%H%M%S).log"

# Enter SQL IDs separated by spaces
SQL_IDS=(
    "SQL_ID_1"
    "SQL_ID_2"
    "SQL_ID_3"
)

mkdir -p "$SOURCE_DIR"

log() {
    echo "$(date '+%F %T') : $*" | tee -a "$LOG"
}

trap 'log "ERROR: Migration failed at line $LINENO"' ERR

# ---------------- SOURCE PL/SQL ----------------

cat > "$SOURCE_DIR/source.sql" <<SQL
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    L_COUNT NUMBER;
    L_TOTAL NUMBER := 0;
BEGIN
    -- Create staging table if it does not exist
    BEGIN
        DBMS_SPM.CREATE_STGTAB_BASELINE(
            TABLE_NAME => '$STAGE'
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != -955 THEN
                RAISE;
            END IF;
    END;

    -- Clear old staging data
    EXECUTE IMMEDIATE 'TRUNCATE TABLE $STAGE';

    -- Load plans for each SQL ID
SQL

for SQL_ID in "${SQL_IDS[@]}"; do
    cat >> "$SOURCE_DIR/source.sql" <<SQL
    L_COUNT := DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE(
        SQL_ID => '$SQL_ID'
    );

    DBMS_OUTPUT.PUT_LINE(
        'SQL_ID=$SQL_ID Loaded=' || L_COUNT
    );
SQL
done

cat >> "$SOURCE_DIR/source.sql" <<SQL

    -- Pack only requested SQL IDs
    FOR B IN (
        SELECT DISTINCT P.SQL_HANDLE
        FROM DBA_SQL_PLAN_BASELINES P
        JOIN V\\$SQL S
          ON DBMS_LOB.COMPARE(
               P.SQL_TEXT, S.SQL_FULLTEXT
          ) = 0
        WHERE S.SQL_ID IN (
SQL

for SQL_ID in "${SQL_IDS[@]}"; do
    echo "            '$SQL_ID'," >> "$SOURCE_DIR/source.sql"
done

# Remove final comma
sed -i '$ s/,$//' "$SOURCE_DIR/source.sql"

cat >> "$SOURCE_DIR/source.sql" <<SQL
        )
        AND P.ENABLED = 'YES'
        AND P.ACCEPTED = 'YES'
    )
    LOOP
        L_COUNT := DBMS_SPM.PACK_STGTAB_BASELINE(
            TABLE_NAME => '$STAGE',
            SQL_HANDLE => B.SQL_HANDLE
        );

        L_TOTAL := L_TOTAL + L_COUNT;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('TOTAL PACKED=' || L_TOTAL);
END;
/

EXIT
SQL

# ---------------- TARGET PL/SQL ----------------

cat > "$SOURCE_DIR/target.sql" <<SQL
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
    L_COUNT NUMBER;
BEGIN
    L_COUNT := DBMS_SPM.UNPACK_STGTAB_BASELINE(
        TABLE_NAME => '$STAGE',
        ENABLED    => 'YES',
        ACCEPTED   => 'YES',
        FIXED      => 'NO'
    );

    DBMS_OUTPUT.PUT_LINE(
        'TOTAL BASELINES IMPORTED=' || L_COUNT
    );
END;
/

SELECT SQL_HANDLE, PLAN_NAME, ENABLED,
       ACCEPTED, FIXED, CREATED
FROM DBA_SQL_PLAN_BASELINES
ORDER BY CREATED DESC;

EXIT
SQL

# ---------------- STEP 1: SOURCE EXTRACTION ----------------

log "Starting source SPM extraction"

sqlplus -s "$SOURCE_CONN" \
    @"$SOURCE_DIR/source.sql" >> "$LOG" 2>&1

log "Source extraction completed"

# ---------------- STEP 2: DATAPUMP EXPORT ----------------

log "Starting Data Pump export"

expdp "$SOURCE_CONN" \
    DIRECTORY="$DP_DIR" \
    TABLES="$STAGE" \
    DUMPFILE="$DUMP" \
    LOGFILE=spm_export.log \
    CONTENT=ALL

log "Data Pump export completed"

# ---------------- STEP 3: TRANSFER ----------------

log "Transferring dump file to target"

scp "${SOURCE_SERVER}:${SOURCE_DIR}/${DUMP}" \
    "${TARGET_SERVER}:${TARGET_DIR}/${DUMP}"

log "File transfer completed"

# ---------------- STEP 4: TARGET IMPORT ----------------

log "Starting target Data Pump import"

ssh "$TARGET_SERVER" "
    impdp '$TARGET_CONN' \
      DIRECTORY='$DP_DIR' \
      DUMPFILE='$DUMP' \
      TABLES='$STAGE' \
      TABLE_EXISTS_ACTION=REPLACE \
      LOGFILE=spm_import.log
"

log "Target import completed"

# ---------------- STEP 5: UNPACK ----------------

log "Unpacking SQL Plan Baselines on target"

scp "$SOURCE_DIR/target.sql" \
    "${TARGET_SERVER}:${TARGET_DIR}/target.sql"

ssh "$TARGET_SERVER" "
    sqlplus -s '$TARGET_CONN' \
      @'$TARGET_DIR/target.sql'
" >> "$LOG" 2>&1

log "SPM unpack completed"

# ---------------- COMPLETED ----------------

log "============================================"
log "SQL PLAN BASELINE MIGRATION SUCCESSFUL"
log "============================================"

echo "Migration log: $LOG"
