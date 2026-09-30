#!/usr/bin/env python3
"""Exercise production tier/metric code with a minimal recipe identity fixture."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
engine=(root/'Stocked/CookNowEngine.swift').read_text()
compute=(root/'Stocked/CookNowCompute.swift').read_text()
def block(text, marker):
 start=text.index(marker); opening=text.index('{',start); depth=1; end=opening+1
 while depth:
  if text[end]=='{': depth+=1
  elif text[end]=='}': depth-=1
  end+=1
 return text[start:end]
source='import Foundation\nnonisolated struct UserRecipe: Identifiable, Codable, Sendable, Equatable { var id=UUID(); var title: String }\n'
source+=engine[engine.index('nonisolated enum CookNowReadiness'):engine.index('// MARK: - Engine')]
source+='\nnonisolated enum CookNowEngine {\n'+block(engine,'static func metrics(')+'\n'+block(engine,'static func morePossibilities(')+'\n}\n'
source+=block(compute,'nonisolated struct Output:').replace('fileprivate mutating','mutating')
source+='''
let fixtures = (0...8).map { count in
 ClassifiedRecipe(recipe: UserRecipe(title: "Gap \\(count)"),
 readiness: count == 0 ? .exact : count == 1 ? .missingOne : count == 2 ? .missingTwo : .missingMany,
 resolutions: (0..<count).map { IngredientResolution(name: "Item \\($0)", amount: "1", status: .missing) })
}
var output = Output(); output.classified = fixtures; output.buildTiers()
let metrics = CookNowEngine.metrics(from: fixtures)
precondition(output.readyNow.map(\\.unresolvedCount) == [0,1,2])
precondition(output.almostReady.map(\\.unresolvedCount) == [3,4,5,6,7,8])
precondition(output.morePossibilities.map(\\.unresolvedCount) == [3,4,5,6,7,8])
precondition(metrics.readyNowTotal == output.readyNow.count)
precondition(metrics.almostReady == output.almostReady.count)
precondition(Set((output.readyNow + output.almostReady).map(\\.id)).count == fixtures.count)
let excluded = ClassifiedRecipe(recipe: UserRecipe(title: "Excluded"), readiness: .excluded, resolutions: fixtures[3].resolutions)
output.classified = [excluded]; output.buildTiers()
precondition(output.readyNow.isEmpty && output.almostReady.isEmpty && output.morePossibilities.isEmpty)
print("Cook tier boundary checks passed: gaps 0–8, dashboard/list parity, complete coverage, excluded recipe safety")
'''
with tempfile.TemporaryDirectory(prefix='stocked-tier-check-') as directory:
 path=Path(directory)/'TierChecks.swift'
 path.write_text(source)
 subprocess.run(['xcrun','swift',str(path)],check=True)
