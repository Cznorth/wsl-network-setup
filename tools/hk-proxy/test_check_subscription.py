import copy
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("check_subscription", pathlib.Path(__file__).with_name("check_subscription.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.base = {"proxies": [{"name": "old", "type": "socks5", "server": "example.org"}],
                     "proxy-groups": [{"name": "old-group", "type": "select", "proxies": ["old"]}],
                     "rules": ["MATCH,old-group"]}
        self.doc = copy.deepcopy(self.base)
        for i in range(4):
            self.doc["proxies"].append({"name": "香港-hkv4-" + str(i), "type": "vless", "tls": True,
                                         "flow": "xtls-rprx-vision", "client-fingerprint": "chrome",
                                         "reality-opts": {"support-x25519mlkem768": True}})

    def test_valid_addition(self):
        self.assertEqual(checker.audit(self.doc, self.base)["total_nodes"], 5)

    def test_reject_missing_node(self):
        self.doc["proxies"].pop()
        with self.assertRaises(ValueError):
            checker.audit(self.doc, self.base)

    def test_reject_removed_legacy_node(self):
        self.doc["proxies"].pop(0)
        with self.assertRaises(ValueError):
            checker.audit(self.doc, self.base)

    def test_reject_missing_mlkem(self):
        self.doc["proxies"][-1]["reality-opts"].clear()
        with self.assertRaises(ValueError):
            checker.audit(self.doc, self.base)

    def test_reject_rule_change(self):
        self.doc["rules"] = ["MATCH,DIRECT"]
        with self.assertRaises(ValueError):
            checker.audit(self.doc, self.base)

    def test_reject_group_change(self):
        self.doc["proxy-groups"] = []
        with self.assertRaises(ValueError):
            checker.audit(self.doc, self.base)

    def test_reject_duplicate(self):
        self.doc["proxies"].append(copy.deepcopy(self.doc["proxies"][-1]))
        with self.assertRaises(ValueError):
            checker.audit(self.doc)


if __name__ == "__main__":
    unittest.main()
