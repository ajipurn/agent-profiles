#!/usr/bin/env python3
"""Regenerate Sources/UsageCostCore/PricingCatalog.swift from LiteLLM's
model price list (MIT). Only Anthropic and OpenAI models are kept: the ones
Claude Code and Codex log. The result is then cross-checked against
models.dev (MIT); disagreements are printed as warnings and change nothing.
Usage: python3 scripts/update-pricing.py [litellm.json [models-dev.json]]"""
import datetime
import json
from pathlib import Path
import re
import sys
import urllib.request

URL = 'https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json'
MODELS_DEV_URL = 'https://models.dev/api.json'
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'Sources/UsageCostCore/PricingCatalog.swift'
PREFIXES = ('claude-', 'gpt-', 'o1', 'o3', 'o4', 'codex-')
FIELDS = {
    'input': 'input_cost_per_token',
    'output': 'output_cost_per_token',
    'cacheRead': 'cache_read_input_token_cost',
    'cacheWrite': 'cache_creation_input_token_cost',
    'cacheWrite1h': 'cache_creation_input_token_cost_above_1hr',
}
# models.dev prices per million tokens and lists one cache write: the 5-minute one.
MODELS_DEV_FIELDS = {'input': 'input', 'output': 'output', 'cacheRead': 'cache_read', 'cacheWrite': 'cache_write'}
LONG = re.compile(r'^input_cost_per_token_above_(\d+)k_tokens$')
# Not in LiteLLM. Anthropic bills fast mode at twice the standard input and
# output rates, with the prompt caching multipliers on top, so every token
# kind doubles: https://platform.claude.com/docs/en/about-claude/pricing#fast-mode-pricing
FAST_MULTIPLIER = {'claude-opus-5-5': 2.0, 'claude-opus-5': 2.0, 'claude-opus-4-8': 2.0}


def load(url, path=None):
    if path:
        return json.loads(Path(path).read_text())
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


def rates(entry, long_suffix='', tier_suffix=''):
    """Per-token rates for one tier and context length, or None."""
    values = {}
    for name, field in FIELDS.items():
        value = entry.get(field + long_suffix + tier_suffix)
        if value is not None:
            values[name] = value
    if 'input' not in values or 'output' not in values:
        return None
    return values


def model_price(key, entry):
    """Every rate set of one model, in ModelPrice's init order, or None."""
    standard = rates(entry)
    if standard is None:
        return None
    price = {'standard': standard}
    threshold = next((int(m.group(1)) for field in entry if (m := LONG.match(field))), None)
    long_suffix = f'_above_{threshold}k_tokens' if threshold else None
    if long_suffix and (long := rates(entry, long_suffix)):
        price['longContext'] = long
        price['longContextThreshold'] = threshold * 1000
    for tier in ('priority', 'flex'):
        if tiered := rates(entry, tier_suffix=f'_{tier}'):
            price[tier] = tiered
        if long_suffix and (tiered_long := rates(entry, long_suffix, f'_{tier}')):
            price[f'{tier}LongContext'] = tiered_long
    if key in FAST_MULTIPLIER:
        price['fastMultiplier'] = FAST_MULTIPLIER[key]
    return price


def swift_price(price):
    args = []
    for name, value in price.items():
        if isinstance(value, dict):
            value = 'Rates(' + ', '.join(f'{field}: {rate!r}' for field, rate in value.items()) + ')'
        else:
            value = repr(value)
        args.append(f'{name}: {value}')
    return 'ModelPrice(\n            ' + ',\n            '.join(args) + ')'


def compare(warnings, key, label, ours, theirs):
    """Warn per field both sources price but disagree on (ours per token, theirs per MTok)."""
    for name, field in MODELS_DEV_FIELDS.items():
        mine, other = ours.get(name), theirs.get(field)
        if mine is None or other is None:
            continue
        mine *= 1_000_000
        if abs(mine - other) > 1e-9 * max(abs(mine), abs(other), 1e-6):
            warnings.append(f'{key} {label} {name}: catalog ${mine:g}/MTok, models.dev ${other:g}/MTok')


def cross_check(prices, models_dev):
    """Where models.dev disagrees with the catalog. LiteLLM stays the source."""
    known = {}
    for provider in ('anthropic', 'openai'):
        known.update((models_dev.get(provider) or {}).get('models') or {})
    warnings = []
    checked = 0
    for key, price in sorted(prices.items()):
        model = known.get(key) or {}
        cost = model.get('cost')
        if not cost:
            continue
        checked += 1
        compare(warnings, key, 'standard', price['standard'], cost)
        context = next((t for t in cost.get('tiers') or []
                        if (t.get('tier') or {}).get('type') == 'context'), None)
        threshold = price.get('longContextThreshold')
        if context:
            size = context['tier'].get('size')
            if threshold != size:
                warnings.append(f'{key} long context: catalog above {threshold}, models.dev above {size}')
            else:
                compare(warnings, key, 'long context', price['longContext'], context)
        elif threshold:
            warnings.append(f'{key} long context: catalog above {threshold}, models.dev has none')
        fast = (((model.get('experimental') or {}).get('modes') or {}).get('fast') or {}).get('cost')
        if fast and key.startswith('claude-'):
            if multiplier := price.get('fastMultiplier'):
                scaled = {name: rate * multiplier for name, rate in price['standard'].items()}
                compare(warnings, key, 'fast', scaled, fast)
            else:
                warnings.append(f'{key} fast: models.dev prices fast mode, catalog has no multiplier')
        elif fast and 'priority' in price:  # OpenAI's fast mode is priority processing
            compare(warnings, key, 'fast/priority', price['priority'], fast)
    return checked, warnings


def main():
    data = load(URL, sys.argv[1] if len(sys.argv) > 1 else None)
    prices = {}
    for key in sorted(data):
        entry = data[key]
        if '/' in key or not key.startswith(PREFIXES) or not isinstance(entry, dict):
            continue
        if entry.get('litellm_provider') not in ('anthropic', 'openai'):
            continue
        if price := model_price(key, entry):
            prices[key] = price
    rows = [f'        "{key}": {swift_price(price)},' for key, price in prices.items()]
    today = datetime.date.today().isoformat()
    OUT.write_text(
        f'// Generated by scripts/update-pricing.py from LiteLLM (MIT) on {today}.\n'
        '// Do not edit by hand; rerun the script to refresh prices.\n\n'
        'extension Pricing {\n'
        '    /// USD per token, keyed by model name.\n'
        '    public static let catalog: [String: ModelPrice] = [\n'
        + '\n'.join(rows) + '\n'
        '    ]\n'
        '}\n')
    print(f'wrote {len(rows)} models to {OUT.relative_to(ROOT)}')

    try:
        models_dev = load(MODELS_DEV_URL, sys.argv[2] if len(sys.argv) > 2 else None)
        checked, warnings = cross_check(prices, models_dev)
    except Exception as error:  # a second opinion only: never block the update
        print(f'warning: models.dev cross-check skipped ({error})')
        return
    for warning in warnings:
        print(f'warning: {warning}')
    print(f'models.dev cross-check: {checked} models compared, {len(warnings)} disagreement(s)')


if __name__ == '__main__':
    main()
