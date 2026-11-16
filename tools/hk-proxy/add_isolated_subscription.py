"""为聚合添加隔离的临时订阅，不让 include-all 自动接管默认/AI 流量。"""
import copy

NAME = 'yuetoto'
GROUP = '悦途临时订阅（11-24到期）'
FILTER = '^悦'


def append_filter(old, new=FILTER):
    return f'(?:{old})|(?:{new})' if old else new


def add_subscription(document, url):
    result = copy.deepcopy(document)
    assert NAME not in result.get('proxy-providers', {})
    provider = copy.deepcopy(result['proxy-providers']['all'])
    provider.update(url=url, path='./proxy_provider/yuetoto.yaml')
    provider.pop('exclude-filter', None)
    provider['filter'] = FILTER
    result['proxy-providers'][NAME] = provider
    result['proxy-providers']['all']['exclude-filter'] = append_filter(
        result['proxy-providers']['all'].get('exclude-filter'))
    for group in result.get('proxy-groups', []):
        if any(group.get(key) for key in ('include-all', 'include-all-providers', 'include-all-proxies')):
            group['exclude-filter'] = append_filter(group.get('exclude-filter'))
    result['proxy-groups'].append({'name': GROUP, 'type': 'select', 'use': [NAME]})
    assert result.get('rules') == document.get('rules')
    assert result.get('proxies') == document.get('proxies')
    return result
