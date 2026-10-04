"""Session-only semantic options: atomic refusal, real readback, cursor invalidation."""
import argparse
import json
from pathlib import Path
from itm_fixture import Client
from row_fixture import TARGET


def exercise(client):
    before = client.call('session.get_dirty_state')
    options = client.call('session.options')
    original = options['values']['udrSetScale']
    plan = client.call('session.set_options', values={'udrSetScale': not original})
    assert plan['dryRun'] and not plan['changed'] and plan['wouldChange'], plan
    assert client.call('session.options')['values'] == options['values']
    for values in ({'udrSetScale': not original, 'sortFLST': True},
                   {'udrSetScale': 1}, {'udrScaleValue': -1}, {'udrZValue': 1e12}, {'unknown': True}):
        result = client.request(json.dumps({'command': 'session.set_options', 'args': {'values': values, 'dryRun': False}}))
        assert not result['ok'], result
        assert client.call('session.options')['values'] == options['values']
    page = client.call('records.apply_filter', files=[TARGET], limit=1)
    assert page['nextCursor'], page
    changed = client.call('session.set_options', values={'udrSetScale': not original},
                          expectedSessionRevision=options['sessionRevision'], dryRun=False)
    assert changed['changed'] and changed['after']['values']['udrSetScale'] == (not original), changed
    stale = client.request(json.dumps({'command': 'session.set_options', 'args': {
        'values': {'udrSetScale': original}, 'expectedSessionRevision': options['sessionRevision'], 'dryRun': False}}))
    assert not stale['ok'] and stale['error']['code'] == 'stale_session_revision', stale
    invalid = client.request(json.dumps({'command': 'records.apply_filter', 'args': {
        'files': [TARGET], 'limit': 1, 'cursor': page['nextCursor']}}))
    assert not invalid['ok'] and invalid['error']['code'] == 'cursor_invalidated', invalid
    link = client.call('session.game_link')
    assert not link['controlSupported'] and link['reason'], link
    for mode in ('disabled', 'reference', 'base', 'inventory', 'enchantment', 'spell'):
        rejected = client.request(json.dumps({'command': 'session.game_link', 'args': {'mode': mode}}))
        assert not rejected['ok'] and rejected['error']['code'] == 'unsupported_game_link_control', rejected
    restored = client.call('session.set_options', values={'udrSetScale': original}, dryRun=False)
    assert restored['changed'] and client.call('session.options')['values'] == options['values']
    assert client.call('session.get_dirty_state') == before


def main():
    p = argparse.ArgumentParser(__doc__)
    p.add_argument('--exe', type=Path, required=True); p.add_argument('--pid', type=int, required=True)
    p.add_argument('--artifacts', type=Path, required=True)
    a = p.parse_args(); exercise(Client(a.exe, a.pid, a.artifacts))


if __name__ == '__main__': main()
