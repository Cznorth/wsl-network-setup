"""为聚合添加隔离的临时订阅，不让 include-all 自动接管默认/AI 流量。"""
import copy

NAME = 'yuetoto'
GROUP = '悦途临时订阅（11-24到期）'
FILTER = '^悦'


def append_filter(old, new=FILTER):
    return f'(?:{old})|(?:{new})' if old else new


def add_subscription(document, url, name=NAME, group=GROUP, node_filter=FILTER):
    result = copy.deepcopy(document)
    assert name not in result.get('proxy-providers', {})
    assert all(g.get('name') != group for g in result.get('proxy-groups', []))
    provider = copy.deepcopy(result['proxy-providers']['all'])
    provider.update(url=url, path=f'./proxy_provider/{name}.yaml')
    provider.pop('exclude-filter', None)
    provider['filter'] = node_filter
    result['proxy-providers'][name] = provider
    result['proxy-providers']['all']['exclude-filter'] = append_filter(
        result['proxy-providers']['all'].get('exclude-filter'), node_filter)
    for g in result.get('proxy-groups', []):
        if any(g.get(key) for key in ('include-all', 'include-all-providers', 'include-all-proxies')):
            g['exclude-filter'] = append_filter(g.get('exclude-filter'), node_filter)
    result['proxy-groups'].append({'name': group, 'type': 'select', 'use': [name]})
    assert result.get('rules') == document.get('rules')
    assert result.get('proxies') == document.get('proxies')
    return result
