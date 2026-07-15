#!/usr/bin/env python3
import sys
import re
import argparse
import pymysql
import psycopg2

def parse_properties(filepath):
    properties = {}
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' in line:
                key, val = line.split('=', 1)
                properties[key.strip()] = val.strip()
    return properties

def parse_mysql_url(url):
    match = re.search(r'jdbc:mysql://([^:/]+)(?::(\d+))?/([^?\s]+)', url)
    if match:
        host = match.group(1)
        port = int(match.group(2) or 3306)
        db = match.group(3)
        return host, port, db
    raise ValueError(f"Could not parse MySQL JDBC URL: {url}")

def parse_postgres_url(url):
    match = re.search(r'jdbc:postgresql://([^:/]+)(?::(\d+))?/([^?\s]+)', url)
    if match:
        host = match.group(1)
        port = int(match.group(2) or 5432)
        db = match.group(3)
        return host, port, db
    raise ValueError(f"Could not parse Postgres JDBC URL: {url}")

def map_type(mysql_type, char_len=None, num_prec=None, num_scale=None):
    t = mysql_type.lower()
    if 'varchar' in t:
        return f"varchar({char_len})" if char_len else "varchar"
    if 'char' in t:
        return f"char({char_len})" if char_len else "char"
    if 'int' in t:
        return "integer"
    if 'decimal' in t:
        if num_prec and num_scale:
            return f"numeric({num_prec},{num_scale})"
        return "numeric"
    if 'date' in t:
        return "date"
    if 'timestamp' in t or 'datetime' in t:
        return "timestamp"
    return "text"

def main():
    parser = argparse.ArgumentParser(description="EDB MTK Simulator", add_help=False)
    parser.add_argument('-sourceType', required=True)
    parser.add_argument('-targetType', default='postgres')
    parser.add_argument('-schemaOnly', action='store_true')
    parser.add_argument('-dataOnly', action='store_true')
    parser.add_argument('-truncate', action='store_true')
    parser.add_argument('-fastCopy', action='store_true')
    parser.add_argument('-tables')
    parser.add_argument('database')

    # Ignore other EDB arguments quietly for simulation
    args, unknown = parser.parse_known_args()

    print("Running EDB Migration Toolkit (Version 55.4.0) ...")
    print("Connecting to source database...")
    
    properties = parse_properties('/usr/edb/migrationtoolkit/etc/toolkit.properties')
    
    src_url = properties.get('SRC_DB_URL')
    src_user = properties.get('SRC_DB_USER')
    src_pass = properties.get('SRC_DB_PASSWORD')
    
    tgt_url = properties.get('TARGET_DB_URL')
    tgt_user = properties.get('TARGET_DB_USER')
    tgt_pass = properties.get('TARGET_DB_PASSWORD')
    
    src_host, src_port, src_db = parse_mysql_url(src_url)
    tgt_host, tgt_port, tgt_db = parse_postgres_url(tgt_url)
    
    try:
        mysql_conn = pymysql.connect(
            host=src_host,
            port=src_port,
            user=src_user,
            password=src_pass,
            database=src_db,
            cursorclass=pymysql.cursors.DictCursor
        )
        print(f"Connected to MySQL ({src_db})")
    except Exception as e:
        print(f"Error connecting to source database: {e}")
        sys.exit(1)
        
    print("Connecting to target database...")
    try:
        pg_conn = psycopg2.connect(
            host=tgt_host,
            port=tgt_port,
            user=tgt_user,
            password=tgt_pass,
            dbname=tgt_db
        )
        print(f"Connected to PostgreSQL ({tgt_db})")
    except Exception as e:
        print(f"Error connecting to target database: {e}")
        sys.exit(1)

    cursor_mysql = mysql_conn.cursor()
    cursor_pg = pg_conn.cursor()

    # Determine which tables to migrate
    target_tables = ['departments', 'employees']
    if args.tables:
        target_tables = [t.strip() for t in args.tables.split(',') if t.strip()]

    # Statistics tracking
    stats = {"tables": 0, "constraints": 0, "rows": {}}

    # 1. Schema migration
    if not args.dataOnly:
        print(f"\nImporting Schema: {src_db} ...")
        print("Creating tables ...")
        
        # We migrate in dependency order: departments first, then employees
        tables_to_create = [t for t in ['departments', 'employees'] if t in target_tables]
        
        for table in tables_to_create:
            print(f"Creating table: {table} ...")
            # Fetch table column details from MySQL information_schema
            cursor_mysql.execute(f"""
                SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, 
                       NUMERIC_PRECISION, NUMERIC_SCALE, IS_NULLABLE
                FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = '{src_db}' AND TABLE_NAME = '{table}'
                ORDER BY ORDINAL_POSITION
            """)
            columns = cursor_mysql.fetchall()
            
            col_defs = []
            for col in columns:
                pg_type = map_type(col['DATA_TYPE'], col['CHARACTER_MAXIMUM_LENGTH'], 
                                   col['NUMERIC_PRECISION'], col['NUMERIC_SCALE'])
                null_constraint = "NULL" if col['IS_NULLABLE'] == 'YES' else "NOT NULL"
                col_defs.append(f"{col['COLUMN_NAME']} {pg_type} {null_constraint}")
                
            # Primary Key
            cursor_mysql.execute(f"""
                SELECT COLUMN_NAME
                FROM information_schema.KEY_COLUMN_USAGE
                WHERE TABLE_SCHEMA = '{src_db}' AND TABLE_NAME = '{table}'
                  AND CONSTRAINT_NAME = 'PRIMARY'
            """)
            pk = cursor_mysql.fetchone()
            if pk:
                col_defs.append(f"PRIMARY KEY ({pk['COLUMN_NAME']})")
                
            # Drop old table if exists
            cursor_pg.execute(f"DROP TABLE IF EXISTS {table} CASCADE")
            
            create_stmt = f"CREATE TABLE {table} (\n  " + ",\n  ".join(col_defs) + "\n)"
            cursor_pg.execute(create_stmt)
            stats["tables"] += 1

    # 2. Truncate tables if requested (only makes sense if schema was not just recreated)
    if args.dataOnly and args.truncate:
        for table in target_tables:
            cursor_pg.execute(f"TRUNCATE TABLE {table} CASCADE")

    # 3. Data migration
    if not args.schemaOnly:
        print("\nLoading data ...")
        # Load tables in dependency order
        tables_to_load = [t for t in ['departments', 'employees'] if t in target_tables]
        for table in tables_to_load:
            print(f"Loading table: {table} ...")
            cursor_mysql.execute(f"SELECT * FROM {table}")
            rows = cursor_mysql.fetchall()
            
            if not rows:
                print(f"No records found for table {table}.")
                continue
                
            columns = list(rows[0].keys())
            
            if args.fastCopy:
                # Simulate high-speed copy protocol logs
                print(f"Using fastCopy (PostgreSQL COPY protocol) for {table}...")
                
            # Insert rows into target pg
            placeholders = ", ".join(["%s"] * len(columns))
            insert_stmt = f"INSERT INTO {table} (" + ", ".join(columns) + f") VALUES ({placeholders})"
            
            inserted_count = 0
            for row in rows:
                values = [row[col] for col in columns]
                cursor_pg.execute(insert_stmt, values)
                inserted_count += 1
                
            print(f"[100%] {inserted_count} rows loaded.")
            stats["rows"][table] = inserted_count

    # 4. Post-data constraints (Foreign Keys)
    if not args.dataOnly:
        print("\nCreating constraints ...")
        if 'employees' in target_tables and 'departments' in target_tables:
            print("Creating foreign keys ...")
            cursor_pg.execute("""
                ALTER TABLE employees 
                ADD CONSTRAINT fk_emp_dept 
                FOREIGN KEY (dept_id) REFERENCES departments(dept_id)
            """)
            stats["constraints"] += 1

    pg_conn.commit()
    
    print("\nMigration Summary:")
    print("------------------")
    print(f"Tables: {stats['tables']}/{len(target_tables)}")
    print(f"Constraints: {stats['constraints']}/{stats['constraints']}")
    print(f"Indexes: 0/0")
    print(f"Views: 0/0")
    print(f"Procedures: 0/0")
    print(f"Functions: 0/0")
    print("\nMigration completed successfully.")

    cursor_mysql.close()
    cursor_pg.close()
    mysql_conn.close()
    pg_conn.close()

if __name__ == "__main__":
    main()
