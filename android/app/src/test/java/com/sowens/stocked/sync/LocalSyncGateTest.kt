package com.sowens.stocked.sync
import org.junit.Assert.*
import org.junit.Test
class LocalSyncGateTest {
 @Test fun initialObservationDoesNotLoop(){val gate=LocalSyncGate();assertFalse(gate.shouldSchedule(0,true));repeat(5){assertFalse(gate.shouldSchedule(0,true))}}
 @Test fun onlyLocalRevisionSchedules(){val gate=LocalSyncGate();gate.shouldSchedule(0,true);assertTrue(gate.shouldSchedule(1,true));assertFalse(gate.shouldSchedule(1,true));assertTrue(gate.shouldSchedule(2,true))}
 @Test fun disconnectedEditsDoNotSchedule(){val gate=LocalSyncGate();gate.shouldSchedule(0,false);assertFalse(gate.shouldSchedule(1,false));assertFalse(gate.shouldSchedule(1,true));assertTrue(gate.shouldSchedule(2,true))}
}
