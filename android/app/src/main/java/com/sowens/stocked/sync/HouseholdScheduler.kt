package com.sowens.stocked.sync

import android.content.Context
import androidx.work.*
import com.sowens.stocked.data.KitchenRepository
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest
import java.util.concurrent.TimeUnit

/** Pure decision gate, excluding sync-journal writes from automatic work scheduling. */
class LocalSyncGate {
 private var last:Long?=null
 fun shouldSchedule(sequence:Long,connected:Boolean):Boolean {
  val previous=last;last=sequence
  return connected && previous!=null && previous!=sequence
 }
}

/** OS-managed network constraints and durable retry; never a perpetual polling loop. */
class HouseholdScheduler(private val context:Context,private val repository:KitchenRepository,private val client:HouseholdClient,private val endpoint:String) {
 companion object { const val PERIODIC="stocked-household-periodic-v1";const val CHANGES="stocked-household-changes-v1";const val ENDPOINT="endpoint" }
 private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
 private val manager=WorkManager.getInstance(context)
 private val constraints=Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
 private fun data()=workDataOf(ENDPOINT to endpoint)
 fun start() {
  if(client.code().isNotEmpty())connected()
  scope.launch {val gate=LocalSyncGate();repository.localChanges.collectLatest{sequence->
   if(gate.shouldSchedule(sequence,client.code().isNotEmpty())){delay(1500);enqueue()}
  }}
 }
 fun connected(){
  val periodic=PeriodicWorkRequestBuilder<HouseholdSyncWorker>(15,TimeUnit.MINUTES).setConstraints(constraints).setInputData(data()).setBackoffCriteria(BackoffPolicy.EXPONENTIAL,30,TimeUnit.SECONDS).build()
  manager.enqueueUniquePeriodicWork(PERIODIC,ExistingPeriodicWorkPolicy.KEEP,periodic)
  enqueue()
 }
 fun enqueue(){
  val request=OneTimeWorkRequestBuilder<HouseholdSyncWorker>().setConstraints(constraints).setInputData(data()).setBackoffCriteria(BackoffPolicy.EXPONENTIAL,30,TimeUnit.SECONDS).build()
  // APPEND_OR_REPLACE retains an edit arriving while the preceding batch is running.
  manager.enqueueUniqueWork(CHANGES,ExistingWorkPolicy.APPEND_OR_REPLACE,request)
 }
 fun disconnected(){manager.cancelUniqueWork(PERIODIC);manager.cancelUniqueWork(CHANGES)}
}

class HouseholdSyncWorker(context:Context,parameters:WorkerParameters):CoroutineWorker(context,parameters) {
 override suspend fun doWork():Result {
  val endpoint=inputData.getString(HouseholdScheduler.ENDPOINT) ?: return Result.failure()
  if(!endpoint.startsWith("https://"))return Result.failure()
  val repository=KitchenRepository.get(applicationContext)
  return try {
   repository.initialize()
   val client=HouseholdClient.get(applicationContext,repository,endpoint)
   if(client.code().isEmpty())return Result.success()
   client.sync()
   if(client.pendingWork())Result.retry() else Result.success()
  }catch(e:CancellationException){throw e}catch(_:Exception){if(runAttemptCount<10)Result.retry() else Result.failure()}
 }
}
