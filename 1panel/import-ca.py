"""
导入现有CA到1panel

crt和key在当前目录，并设置CA_NAME，KEY_TYPE环境变量
"""

import sqlite3
import pathlib
import sys
import os

db = "/opt/1panel/db/agent.db"
ca_name = os.environ.get("CA_NAME")
key_type = os.environ.get("KEY_TYPE")

crt_path = pathlib.Path("ca.crt")
key_path = pathlib.Path("ca.key")

csr = crt_path.read_text()
private_key = key_path.read_text()

con = sqlite3.connect(db)
cur = con.cursor()

cur.execute("select id from website_cas where name = ?", (ca_name,))
if cur.fetchone():
    print(f"CA 名称已存在: {ca_name}")
    sys.exit(1)

cur.execute("""
insert into website_cas
(created_at, updated_at, csr, name, private_key, key_type)
values
(datetime('now'), datetime('now'), ?, ?, ?, ?)
""", (csr, ca_name, private_key, key_type))

con.commit()
print("导入成功，ID:", cur.lastrowid)
