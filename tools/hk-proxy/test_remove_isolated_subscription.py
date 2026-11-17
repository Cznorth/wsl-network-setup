import unittest

from add_isolated_subscription import add_subscription
from remove_isolated_subscription import remove_from_template
from test_add_isolated_subscription import IsolationTests


class RemoveTests(unittest.TestCase):
    def test_round_trip(self):
        case = IsolationTests('test_no_mutation')
        case.setUp()
        first = add_subscription(case.old, 'https://example.invalid/a')
        second = add_subscription(first, 'https://example.invalid/b', name='bbcloud',
                                  group='BBcloud 1T（11-18到期）', node_filter='^BB-')
        self.assertEqual(remove_from_template(second, 'bbcloud', 'BBcloud 1T（11-18到期）', '^BB-'), first)
        self.assertEqual(remove_from_template(first, 'yuetoto', '悦途临时订阅（11-24到期）', '^悦'), case.old)
