"""Assert intentionally excluded diagnostics reject without session/plugin changes."""
import argparse
import json
from pathlib import Path
from itm_fixture import Client


def exercise(client):
    before = client.call('session.get_dirty_state')
    rows = client.call('system.diagnostics')['diagnostics']
    assert {row['name'] for row in rows} == {'test', 'bandit_fix', 'race_lvli_fix'}
    for row in rows:
        assert not row['supported'] and row['reason'] and row['alternative'], row
        response = client.request(json.dumps({'command': 'system.run_diagnostic', 'args': {'name': row['name']}}))
        assert not response['ok'] and response['error']['code'] == 'unsupported_diagnostic', response
        assert response['error']['details']['name'] == row['name'], response
    assert client.call('session.get_dirty_state') == before


def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--pid', type=int, required=True)
    p.add_argument('--artifacts', type=Path, required=True)
    a = p.parse_args()
    exercise(Client(a.exe, a.pid, a.artifacts))


if __name__ == '__main__': main()
