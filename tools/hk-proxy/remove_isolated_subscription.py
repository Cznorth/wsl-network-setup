"""到期后移除 add_isolated_subscription.py 加入的临时订阅（服务器上运行）。

用法：python3 -I remove_isolated_subscription.py bbcloud 'BBcloud 1T（11-18到期）' '^BB-'
"""
import copy
import json
import sys
import urllib.request

API = 'http://127.0.0.1:3001/1e97f0b8524f15f67a87701a8d10f122'
STORE = '/opt/sub-store/data/sub-store.json'


def strip_filter(value, node_filter):
    if value == node_filter:
        return None
    suffix = f'|(?:{node_filter})'
    if value and value.startswith('(?:') and value.endswith(')' + suffix):
        return value[3:-len(suffix) - 1]
    return value


def remove_from_template(document, name, group, node_filter):
    result = copy.deepcopy(document)
    result['proxy-providers'].pop(name, None)
    result['proxy-groups'] = [g for g in result['proxy-groups'] if g.get('name') != group]
    targets = [result['proxy-providers']['all']] + result['proxy-groups']
    for item in targets:
        if 'exclude-filter' in item:
            value = strip_filter(item['exclude-filter'], node_filter)
            if value is None:
                del item['exclude-filter']
            else:
                item['exclude-filter'] = value
    assert result.get('rules') == document.get('rules')
    return result


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method,
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status


def main(name, group, node_filter):
    import yaml
    store = json.load(open(STORE))
    col = [c for c in store['collections'] if c['name'] == 'all'][0]
    col = dict(col, subscriptions=[s for s in col['subscriptions'] if s != name])
    print('patch collection', call('PATCH', '/api/collection/all', col))
    if any(s['name'] == name for s in store['subs']):
        print('delete sub', call('DELETE', f'/api/sub/{name}'))
    f = [x for x in store['files'] if x['name'] == 'clash'][0]
    new = remove_from_template(yaml.safe_load(f['content']), name, group, node_filter)
    content = yaml.safe_dump(new, allow_unicode=True, sort_keys=False)
    print('patch file', call('PATCH', '/api/file/clash', dict(f, content=content)))


if __name__ == '__main__':
    main(*sys.argv[1:4])
