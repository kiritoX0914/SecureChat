#!/usr/bin/env python3
"""
SecureChat Automated E2E Test Runner
Executes all 4 test tiers:
  Tier 1: Feature Coverage (30 tests)
  Tier 2: Boundary & Corner Cases (30 tests)
  Tier 3: Cross-Feature Combinations (16 tests)
  Tier 4: Real-World Workload Scenarios (4 tests)

Returns exit code 0 when all tests pass, non-zero on failure.
"""

import sys
import os
import time
import unittest
import argparse

# Add Tests directory to sys.path
TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

import test_tier1_features
import test_tier2_boundary
import test_tier3_combinations
import test_tier4_workloads

TIERS = {
    1: ("Tier 1: Feature Coverage", test_tier1_features),
    2: ("Tier 2: Boundary & Corner Cases", test_tier2_boundary),
    3: ("Tier 3: Cross-Feature Combinations", test_tier3_combinations),
    4: ("Tier 4: Real-World Workload Scenarios", test_tier4_workloads),
}


def run_tier(tier_num: int, tier_name: str, module, verbosity: int = 1):
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(module)
    num_tests = suite.countTestCases()

    print(f"\n{'='*70}")
    print(f"  RUNNING [{tier_name}] ({num_tests} tests)")
    print(f"{'='*70}")

    runner = unittest.TextTestRunner(verbosity=verbosity)
    t0 = time.time()
    result = runner.run(suite)
    duration = time.time() - t0

    return {
        "tier": tier_num,
        "name": tier_name,
        "tests": result.testsRun,
        "failures": len(result.failures),
        "errors": len(result.errors),
        "skipped": len(result.skipped),
        "passed": result.testsRun - len(result.failures) - len(result.errors) - len(result.skipped),
        "duration": duration,
        "success": result.wasSuccessful(),
    }


def main():
    parser = argparse.ArgumentParser(description="SecureChat Comprehensive E2E Test Runner")
    parser.add_argument("--tier", type=int, choices=[1, 2, 3, 4], help="Run only specific tier (1-4)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Enable verbose test output")
    args = parser.parse_args()

    verbosity = 2 if args.verbose else 1

    print("=" * 70)
    print("      SecureChat 4-Tier Opaque-Box E2E Test Suite Runner")
    print(f"      Root Directory: {os.path.abspath(os.path.join(TESTS_DIR, '..'))}")
    print("=" * 70)

    selected_tiers = [args.tier] if args.tier else [1, 2, 3, 4]

    results = []
    overall_start = time.time()

    for t_num in selected_tiers:
        name, mod = TIERS[t_num]
        res = run_tier(t_num, name, mod, verbosity=verbosity)
        results.append(res)

    total_duration = time.time() - overall_start

    # Final Summary Table
    print("\n" + "=" * 70)
    print("                      TEST SUITE EXECUTION SUMMARY")
    print("=" * 70)
    header = f"{'Tier':<4} | {'Tier Name':<38} | {'Tests':<6} | {'Pass':<5} | {'Fail':<5} | {'Time':<7}"
    print(header)
    print("-" * len(header))

    total_tests = 0
    total_passed = 0
    total_failed = 0
    all_success = True

    for r in results:
        status_str = f"{r['tier']:<4} | {r['name']:<38} | {r['tests']:<6} | {r['passed']:<5} | {r['failures'] + r['errors']:<5} | {r['duration']:<6.3f}s"
        print(status_str)
        total_tests += r["tests"]
        total_passed += r["passed"]
        total_failed += (r["failures"] + r["errors"])
        if not r["success"]:
            all_success = False

    print("-" * len(header))
    summary_str = f"{'ALL':<4} | {'Total Across Tiers':<38} | {total_tests:<6} | {total_passed:<5} | {total_failed:<5} | {total_duration:<6.3f}s"
    print(summary_str)
    print("=" * 70)

    if all_success:
        print("\n [PASS] 100% of SecureChat E2E tests PASSED. All gates satisfied.")
        return 0
    else:
        print(f"\n [FAIL] {total_failed} test(s) FAILED out of {total_tests} executed.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
