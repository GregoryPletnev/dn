"""Databases (Ctrl-Q): the connection manager, a database in a panel, the
grid, the SQL window, CSV export, and passwords (prompt, vault, master
password). SQLite runs for real; psql and clickhouse are fake scripts that
record how dn called them (DN_DB_PSQL / DN_DB_CLICKHOUSE)."""

import os
import shutil
import subprocess
import textwrap

import pytest

from conftest import make_session

needs_sqlite = pytest.mark.skipif(shutil.which('sqlite3') is None,
                                  reason='no sqlite3')


def write_registry(sandbox, text):
    cfg = sandbox / 'cfg'
    cfg.mkdir(exist_ok=True)
    (cfg / 'databases').write_text(textwrap.dedent(text))


def open_manager(s):
    s.wait_text('Name')
    s.key('CTRL_Q')
    s.wait_text('Enter panel')


def type_line(s, text):
    s.send(text)
    s.key('ENTER')


# --- SQLite, for real ---------------------------------------------------------

@pytest.fixture
def shop(sandbox):
    db = sandbox / 'shop.db'
    subprocess.run(['sqlite3', str(db)], text=True, check=True, input=(
        "create table items(id int, name text, price real);"
        "insert into items values (1,'apple',1.5),(2,'pear, green',2.25);"
        "create view cheap as select * from items where price < 2;"))
    write_registry(sandbox, '''
        [shop]
        kind=sqlite
        database=%s
        ''' % db)
    return sandbox


@needs_sqlite
def test_sqlite_panel_grid_and_export(shop):
    s = make_session(shop)
    try:
        open_manager(s)
        assert s.row_of('shop') is not None
        s.key('ENTER')                          # open in the panel
        s.wait_text('db://shop/')
        s.wait_text('items')
        assert s.row_of('cheap') is not None    # views are listed too
        s.click_on('items', panel='left')
        s.key('ENTER')                          # the rows in a grid
        s.wait_text('pear, green')
        s.wait_text('row 1/2')
        s.key('ESC')
        s.wait_gone('pear, green')
        s.key('F5')                             # export to the right panel
        s.wait_text('Copy')
        s.key('ENTER')
        out = shop / 'right' / 'items'
        s.wait_for(lambda _: out.exists() and out.stat().st_size > 0,
                   desc='CSV export written')
        text = out.read_text()
        assert text.splitlines()[0] == 'id,name,price'
        assert '"pear, green"' in text
    finally:
        s.close()


@needs_sqlite
def test_sqlite_sql_window_runs_the_block_under_the_cursor(shop):
    s = make_session(shop)
    try:
        open_manager(s)
        s.key('F2')                             # SQL window
        s.wait_text('Ctrl-R run')
        type_line(s, 'SELECT 1 AS one;')
        s.key('ENTER')                          # a blank line ends the block
        s.send('SELECT name, price FROM items WHERE price > 2;')
        s.key('CTRL_R')
        s.wait_text('Result: shop')
        s.wait_text('pear, green')
        assert not any(l.lstrip('║│ ').startswith('one') for l in s.display()), \
            'ran the other block too'
        s.key('UP')
        s.key('UP')
        s.key('CTRL_R')                         # now the first block
        s.wait_text('row 1/1')
        s.wait_gone('pear, green')
        s.send('x')                             # an error shows a message
        s.key('END')
        s.send(' FROM nowhere')
        s.key('CTRL_R')
        s.wait_text('SQL error')
    finally:
        s.close()
    # the scratch text is kept for the next session
    kept = list((shop / 'cfg' / 'sql').glob('*.sql'))
    assert kept and 'SELECT name, price' in kept[0].read_text()


@needs_sqlite
def test_manager_adds_a_connection(sandbox):
    db = sandbox / 'new.db'
    subprocess.run(['sqlite3', str(db), 'create table t(a);'], check=True)
    s = make_session(sandbox)
    try:
        open_manager(s)
        s.wait_text('no connections')
        s.key('INS')
        s.wait_text('Name:')
        type_line(s, 'fresh')
        s.wait_text('Database kind')
        s.key('DOWN')
        s.key('DOWN')
        s.key('ENTER')                          # SQLite
        s.wait_text('Database file')
        type_line(s, str(db))
        s.wait_text('Extra client options')
        s.key('ENTER')
        s.wait_text('Folder')
        type_line(s, 'local')
        s.wait_text('local/')                   # back in the list, in a folder
        s.key('F5')
        s.wait_text('connected')
    finally:
        s.close()
    reg = (sandbox / 'cfg' / 'databases').read_text()
    assert '[fresh]' in reg and 'kind=sqlite' in reg and 'folder=local' in reg


# --- PostgreSQL / ClickHouse through fake clients ------------------------------

FAKE_PSQL = r'''#!/bin/sh
printf '%s\n' "$@" > "$FAKE_LOG.args"
cat > "$FAKE_LOG.sql"
if [ "$PGPASSWORD" != "Pa55-w0rd" ]; then
  echo 'psql: error: connection to server at "db.example" failed: FATAL:  password authentication failed for user "app"' >&2
  exit 2
fi
case "$(cat "$FAKE_LOG.sql")" in
  *pg_class*) printf 'relname,relkind,reltuples\norders,table,1234\n' ;;
  *pg_namespace*) printf 'nspname\npublic\nsales\n' ;;
  *) printf 'id,name\n1,Ann\n' ;;
esac
'''

FAKE_CLICKHOUSE = r'''#!/bin/sh
printf '%s\n' "$@" > "$FAKE_LOG.args"
cat > "$FAKE_LOG.sql"
cfg=""
while [ $# -gt 0 ]; do
  [ "$1" = "--config-file" ] && cfg="$2"
  shift
done
if [ -z "$cfg" ] || ! grep -q '<password>ch&amp;pw</password>' "$cfg"; then
  echo 'Code: 516. DB::Exception: default: Authentication failed: password is incorrect.' >&2
  exit 4
fi
case "$(cat "$FAKE_LOG.sql")" in
  *system.databases*) printf 'name\ndefault\nlogs\n' ;;
  *system.tables*) printf 'name,engine,total_rows\nhits,mergetree,99\n' ;;
  *) printf 'x\n1\n' ;;
esac
'''


def fake_client(sandbox, name, body):
    path = sandbox / name
    path.write_text(body)
    path.chmod(0o755)
    return str(path)


def test_postgres_password_prompt_vault_and_reuse(sandbox):
    psql = fake_client(sandbox, 'fake-psql', FAKE_PSQL)
    log = str(sandbox / 'pg')
    write_registry(sandbox, '''
        [prod]
        kind=postgres
        host=db.example
        user=app
        database=main
        ''')
    env = {'DN_DB_PSQL': psql, 'FAKE_LOG': log}
    s = make_session(sandbox, env=env)
    try:
        open_manager(s)
        s.key('ENTER')
        s.wait_text('Password for prod (app)')  # the login failed: ask
        type_line(s, 'Pa55-w0rd')
        s.wait_text('Save this password in the vault?')
        s.key('ENTER')                          # Yes
        s.wait_text('Choose a master password')
        type_line(s, 'm4ster')
        s.wait_text('again')
        type_line(s, 'm4ster')
        s.wait_text('db://prod/')
        s.wait_text('sales')
        s.click_on('sales', panel='left')
        s.key('ENTER')
        s.wait_text('orders')
        s.wait_text('1234')                     # the row estimate as the size
    finally:
        s.close()
    args = open(log + '.args').read()
    assert 'Pa55-w0rd' not in args, 'the password is on the command line'
    assert '-h\ndb.example' in args and '-U\napp' in args and '--csv' in args
    vault = (sandbox / 'cfg' / 'vault.db').read_bytes()
    assert b'Pa55-w0rd' not in vault
    assert 'save_password=1' in (sandbox / 'cfg' / 'databases').read_text()

    # a new dn: the saved password is used, only the master password asked
    s = make_session(sandbox, env=env)
    try:
        open_manager(s)
        s.key('ENTER')
        s.wait_text('Master password')
        type_line(s, 'm4ster')
        s.wait_text('sales')
        assert s.row_of('Password for prod') is None
    finally:
        s.close()


def test_clickhouse_password_goes_through_a_config_file(sandbox):
    ch = fake_client(sandbox, 'fake-clickhouse', FAKE_CLICKHOUSE)
    log = str(sandbox / 'ch')
    write_registry(sandbox, '''
        [logs]
        kind=clickhouse
        host=ch.example
        port=9000
        user=default
        ''')
    s = make_session(sandbox, env={'DN_DB_CLICKHOUSE': ch, 'FAKE_LOG': log})
    try:
        open_manager(s)
        s.key('ENTER')
        s.wait_text('Password for logs')
        type_line(s, 'ch&pw')                   # XML-escaped in the file
        s.wait_text('Save this password')
        s.key('RIGHT')
        s.key('ENTER')                          # No: no vault involved
        s.wait_text('db://logs/')
        s.wait_text('default')
        s.click_on('logs ', panel='left')
        s.key('ENTER')
        s.wait_text('hits')
    finally:
        s.close()
    args = open(log + '.args').read()
    assert 'ch&pw' not in args
    assert '--host\nch.example' in args and '--format\nCSVWithNames' in args
    assert not (sandbox / 'cfg' / 'vault.db').exists()
    leftovers = [p for p in os.listdir(os.environ.get('TMPDIR', '/tmp'))
                 if p.startswith('dn-ch-')]
    assert not leftovers, 'the password file was left behind'


# --- SQLite files open as databases ---------------------------------------------

def make_sqlite(path):
    subprocess.run(['sqlite3', str(path)], check=True, text=True,
                   input='create table notes(id int, body text);'
                         "insert into notes values (1, 'hello');")


@needs_sqlite
@pytest.mark.parametrize('name,key', [('app.db', 'F3'), ('data.sqlite3', 'F4'),
                                      ('x.s3db', 'ENTER'), ('y.sqlite', 'F3'),
                                      ('z.sql3', 'ENTER'), ('History', 'F3'),
                                      ('cache.bin', 'ENTER')])
def test_sqlite_file_opens_as_database(sandbox, name, key):
    make_sqlite(sandbox / 'left' / name)
    s = make_session(sandbox)
    try:
        s.wait_text(name)
        s.click_on(name, panel='left')
        s.key(key)
        s.wait_text('db://%s/' % name)
        s.wait_text('notes')
        s.click_on('..', panel='left')          # back out of the database
        s.key('ENTER')
        s.wait_gone('db://%s/' % name)
        s.wait_for(lambda x: name in x.cursor_bar_text(),
                   desc='the cursor is back on the file')
    finally:
        s.close()


@needs_sqlite
def test_db_extension_without_sqlite_header_stays_a_file(sandbox):
    (sandbox / 'left' / 'notes.db').write_text('just text, not a database\n')
    s = make_session(sandbox)
    try:
        s.wait_text('notes.db')
        s.click_on('notes.db', panel='left')
        s.key('F3')
        s.wait_text('just text, not a database')    # the plain viewer
        assert s.row_of('db://') is None
    finally:
        s.close()


@needs_sqlite
def test_sqlite_panel_lists_tables_without_counting_rows(sandbox):
    """The panel listing must not run count(*) over every table: on a large
    database that hangs the panel. The rows come back unknown (blank size)."""
    db = sandbox / 'left' / 'app.db'
    subprocess.run(['sqlite3', str(db)], check=True, text=True,
                   input='create table big(n int);'
                         'with recursive c(n) as (select 1 union all '
                         'select n + 1 from c where n < 4321) '
                         'insert into big select n from c;'
                         'create view v as select n from big;'
                         'create virtual table gone using fts5(body);')
    s = make_session(sandbox)
    try:
        s.wait_text('app.db')
        s.click_on('app.db', panel='left')
        s.key('F3')
        s.wait_text('big')                      # the table is listed
        s.wait_text('v')                        # the view is listed too
        assert s.row_of('4321') is None         # the count is not computed
    finally:
        s.close()


@needs_sqlite
def test_wheel_scrolls_the_grid_rows(sandbox):
    db = sandbox / 'left' / 'app.db'
    subprocess.run(['sqlite3', str(db)], check=True, text=True,
                   input='create table things(name text);'
                         'with recursive c(n) as (select 1 union all '
                         'select n + 1 from c where n < 80) '
                         "insert into things select printf('item%03d', n) from c;")
    s = make_session(sandbox)
    try:
        s.wait_text('app.db')
        s.click_on('app.db', panel='left')
        s.key('F3')
        s.wait_text('db://app.db/')
        s.wait_text('things')
        s.click_on('things', panel='left')
        s.key('F3')
        s.wait_text('item001')
        r = s.row_of('item001')
        s.mouse(20, r + 5, button='wheeldown')
        s.wait_text('row 4/80')                 # three rows, pointer ignored
        assert s.row_of('item003') is None and s.row_of('item004') == r
        s.mouse(20, r + 5, button='wheelup')
        s.wait_text('row 4/80')                 # the cursor stays where it was
        s.wait_text('item001')
    finally:
        s.close()


@needs_sqlite
def test_sqlite_file_table_rows_from_the_panel(sandbox):
    make_sqlite(sandbox / 'left' / 'app.db')
    s = make_session(sandbox)
    try:
        s.wait_text('app.db')
        s.click_on('app.db', panel='left')
        s.key('F3')
        s.wait_text('notes')
        s.click_on('notes', panel='left')
        s.key('F3')                              # F3 on a table: the grid
        s.wait_text('hello')
    finally:
        s.close()
    # an opened file does not land in the registry
    assert not (sandbox / 'cfg' / 'databases').exists()
