import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'update-pricing.py'
spec = importlib.util.spec_from_file_location('update_pricing', SCRIPT)
update_pricing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update_pricing)


class CrossCheckTests(unittest.TestCase):
    haiku = {
        'input_cost_per_token': 1e-07, 'output_cost_per_token': 5e-07,
        'cache_read_input_token_cost': 1e-08, 'cache_creation_input_token_cost': 1.25e-07,
        'input_cost_per_token_above_100k_tokens': 5e-07, 'output_cost_per_token_above_100k_tokens': 2.5e-06,
        'cache_read_input_token_cost_above_100k_tokens': 5e-08,
        'input_cost_per_token_above_100k_tokens_batches': 2.5e-07,  # anchored regex skips batches
    }

    def models_dev(self, **cost):
        base = {'input': 0.1, 'output': 0.5, 'cache_read': 0.01, 'cache_write': 0.125,
                'tiers': [{'input': 0.5, 'output': 2.5, 'cache_read': 0.05, 'tier': {'type': 'context', 'size': 100000}}]}
        return {'anthropic': {'models': {'claude-haiku-5-5': {'cost': base | cost}}}}

    def check(self, models_dev):
        price = update_pricing.model_price('claude-haiku-5-5', self.haiku)
        return update_pricing.cross_check({'claude-haiku-5-5': price}, models_dev)

    def test_reads_the_100k_long_context_tier(self):
        price = update_pricing.model_price('claude-haiku-5-5', self.haiku)
        self.assertEqual(price['longContextThreshold'], 100000)
        self.assertEqual(price['longContext']['input'], 5e-07)

    def test_matching_sources_give_no_warnings(self):
        self.assertEqual(self.check(self.models_dev()), (1, []))

    def test_disagreement_is_reported_per_field(self):
        checked, warnings = self.check(self.models_dev(cache_read=0.02))
        self.assertEqual(checked, 1)
        self.assertEqual(len(warnings), 1)
        self.assertIn('standard cacheRead', warnings[0])

    def test_threshold_mismatch_is_reported(self):
        tiers = [{'input': 0.5, 'output': 2.5, 'tier': {'type': 'context', 'size': 200000}}]
        _, warnings = self.check(self.models_dev(tiers=tiers))
        self.assertEqual(len(warnings), 1)
        self.assertIn('above 100000', warnings[0])

    def test_fast_mode_is_compared_through_the_multiplier(self):
        entry = {'input_cost_per_token': 4e-06, 'output_cost_per_token': 2e-05}
        price = update_pricing.model_price('claude-opus-5-5', entry)
        model = {'cost': {'input': 4, 'output': 20},
                 'experimental': {'modes': {'fast': {'cost': {'input': 8, 'output': 50}}}}}
        _, warnings = update_pricing.cross_check({'claude-opus-5-5': price},
                                                 {'anthropic': {'models': {'claude-opus-5-5': model}}})
        self.assertEqual(len(warnings), 1)
        self.assertIn('fast output', warnings[0])

    def test_models_missing_from_models_dev_are_skipped(self):
        self.assertEqual(self.check({'anthropic': {'models': {}}}), (0, []))


if __name__ == '__main__':
    unittest.main()
