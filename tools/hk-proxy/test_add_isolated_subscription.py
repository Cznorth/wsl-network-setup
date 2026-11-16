import copy
import re
import unittest

from add_isolated_subscription import add_subscription, GROUP


class IsolationTests(unittest.TestCase):
    def setUp(self):
        self.old = {'proxy-providers': {'all': {'type': 'http', 'url': 'https://example.invalid/all',
                    'path': './proxy_provider/all.yaml', 'exclude-filter': '流量', 'proxy': '香港入口'}},
                    'proxy-groups': [{'name': '自动选择', 'type': 'url-test', 'include-all': True},
                                     {'name': 'Claude', 'type': 'select', 'proxies': ['美国']},
                                     {'name': '香港及家宽出口', 'type': 'select', 'proxies': ['香港入口']}],
                    'rules': ['MATCH,自动选择'], 'proxies': []}

    def test_no_mutation(self):
        baseline = copy.deepcopy(self.old)
        new = add_subscription(self.old, 'https://example.invalid/new')
        self.assertEqual(self.old, baseline)
        self.assertEqual(new['rules'], baseline['rules'])
        self.assertEqual(new['proxies'], baseline['proxies'])
        self.assertEqual(new['proxy-groups'][1:3], baseline['proxy-groups'][1:3])

    def test_default_isolation(self):
        new = add_subscription(self.old, 'https://example.invalid/new')
        for name in ['悦 · 香港家宽', '悦 · 美国 AI']:
            self.assertTrue(re.search(new['proxy-providers']['all']['exclude-filter'], name))
            self.assertTrue(re.search(new['proxy-groups'][0]['exclude-filter'], name))
        self.assertFalse(re.search(new['proxy-groups'][0]['exclude-filter'], '香港入口'))
        self.assertEqual(new['proxy-groups'][-1], {'name': GROUP, 'type': 'select', 'use': ['yuetoto']})
        self.assertEqual(new['proxy-providers']['yuetoto']['proxy'], '香港入口')
        self.assertNotIn('exclude-filter', new['proxy-providers']['yuetoto'])

    def test_reject_duplicate(self):
        new = add_subscription(self.old, 'https://example.invalid/new')
        with self.assertRaises(AssertionError):
            add_subscription(new, 'https://example.invalid/new')
