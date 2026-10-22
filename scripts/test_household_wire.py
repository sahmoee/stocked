#!/usr/bin/env python3
"""Run the actual pure JVM test suites without an Android SDK or Gradle build.
Uses cached Kotlin 2.0.21/serialization jars; --baseline expects fe08de9's known
HouseholdWire failures. No network, app storage or production operations.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT/'android/app/src/main/java/com/sowens/stocked'
TEST = ROOT/'android/app/src/test/java/com/sowens/stocked'

def block(text, signature):
    start=text.index(signature); cursor=text.index('{', start)+1; depth=1
    while depth:
        depth += (text[cursor]=='{')-(text[cursor]=='}'); cursor+=1
    return text[start:cursor]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',action='store_true')
    args=parser.parse_args()
    cache=Path.home()/'.gradle/caches/modules-2/files-2.1'
    def jar(group, artifact, version): return next((cache/group/artifact/version).glob('*/*.jar'))
    java=Path.home()/'.local/share/java/zulu21.52.203-ca-jdk21.0.12.1-macosx_x64/Contents/Home/bin/java'
    compiler=[jar('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.0.21'),jar('org.jetbrains.kotlin','kotlin-stdlib','2.0.21'),jar('org.jetbrains.intellij.deps','trove4j','1.0.20200330'),jar('org.jetbrains','annotations','13.0')]
    compiler+=list((cache/'org.jetbrains.kotlin/kotlin-script-runtime/2.0.21').glob('*/*.jar'))
    compiler+=list((cache/'org.jetbrains.kotlin/kotlin-reflect').glob('*/*/*.jar'))[:1]
    coroutines=next((cache/'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm').glob('*/*/*.jar'))
    compiler.append(coroutines)
    runtime=[jar('org.jetbrains.kotlin','kotlin-stdlib','2.0.21'),jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.7.3'),jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.7.3'),jar('org.jetbrains','annotations','13.0'),jar('junit','junit','4.13.2'),jar('org.hamcrest','hamcrest-core','1.3'),jar('org.json','json','20240303'),jar('com.squareup.okhttp3','okhttp','4.12.0'),jar('com.squareup.okio','okio-jvm','3.6.0'),coroutines]
    plugin=jar('org.jetbrains.kotlin','kotlin-serialization-compiler-plugin-embeddable','2.0.21')
    with tempfile.TemporaryDirectory(prefix='stocked-household-wire-') as directory:
        work=Path(directory)
        sources=[MAIN/p for p in ['data/Models.kt','data/KitchenRules.kt','data/BackupCodec.kt','sync/HouseholdWire.kt','imports/RecipeImporter.kt','imports/RecipeWebFetcher.kt','ui/RecipeQuantities.kt','ui/TimerRules.kt']]
        # Extract only the two pure declarations from files with Android service
        # imports. Their complete production bodies are unchanged, never stubbed.
        for path,signature,package in [('data/KitchenRepository.kt','object LocalInventoryBatch','data'),('sync/HouseholdScheduler.kt','class LocalSyncGate','sync')]:
            output=work/(signature.split()[-1]+'.kt')
            output.write_text('package com.sowens.stocked.'+package+'\n'+block((MAIN/path).read_text(),signature)+'\n')
            sources.append(output)
        if args.baseline:
            old=work/'HouseholdWire.kt'
            old.write_text(subprocess.check_output(['git','show','fe08de9:android/app/src/main/java/com/sowens/stocked/sync/HouseholdWire.kt'],cwd=ROOT,text=True))
            sources[3]=old
        tests=sorted(TEST.rglob('*Test.kt'))
        sources+=tests
        classes=['com.sowens.stocked.'+'.'.join(p.relative_to(TEST).with_suffix('').parts) for p in tests]
        output=work/'classes'
        subprocess.run([str(java),'-Xmx512m','-cp',os.pathsep.join(map(str,compiler)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-jvm-target','17','-classpath',os.pathsep.join(map(str,runtime)),'-Xplugin='+str(plugin),'-d',str(output)]+list(map(str,sources)),check=True)
        result=subprocess.run([str(java),'-Xmx512m','-cp',os.pathsep.join(map(str,[output,ROOT/'android/app/src/test/resources']+runtime)),'org.junit.runner.JUnitCore']+classes,capture_output=True,text=True)
        print(result.stdout,end=''); print(result.stderr,end='')
        if args.baseline:
            names={'androidZonesUseReleasedIOSWireKey','iosZoneImportsWithoutChangingStorageOrUnknownMetadata','androidRecipesAndMealsSupplyRequiredIOSCodableFields','canonicalBackupFeedsAllReleasedHouseholdCollections','nonemptyHouseholdRoundTripPreservesUnknownFieldsAndKnownDates'}
            import re
            actual=set(re.findall(r'^\d+\) (\w+)\(',result.stdout,re.M))
            if result.returncode!=1 or actual!=names: raise SystemExit('Unexpected baseline failures: '+repr(actual))
            print('CONFIRMED exactly five HouseholdWire baseline failures (three hosted plus two new regressions)')
        elif result.returncode: raise SystemExit(result.returncode)

if __name__=='__main__': main()
