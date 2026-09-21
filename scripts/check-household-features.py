#!/usr/bin/env python3
"""Compile native checks against production sync code and its exact backup declaration."""
from pathlib import Path
import subprocess
import sys

repo = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
source = (repo / 'Stocked/KitchenTransferManager.swift').read_text()
start = source.index('nonisolated struct KitchenFeatureSnapshot:')
end = source.index('\n// MARK: - Versioned backup contract', start)
(out / 'KitchenFeatureSnapshot.swift').write_text('import Foundation\n' + source[start:end])
files = ['Stocked/HouseholdModels.swift', 'Stocked/HouseholdMergePolicy.swift', 'Stocked/FeatureHouseholdSync.swift',
         'Stocked/PlanAheadCore.swift', 'Stocked/SmartCookbookCore.swift', 'scripts/HouseholdFeatureChecks.swift']
binary = out / 'household-feature-checks'
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *[str(repo / file) for file in files],
                str(out / 'KitchenFeatureSnapshot.swift'), '-o', str(binary)], check=True)
subprocess.run([str(binary)], check=True)
