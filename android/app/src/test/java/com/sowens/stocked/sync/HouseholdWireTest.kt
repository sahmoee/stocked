package com.sowens.stocked.sync
import kotlinx.serialization.json.*
import org.junit.Test
import org.junit.Assert.*
class HouseholdWireTest {
 private fun doc(quantity:Int,name:String="Milk")=buildJsonObject{put("inventory",buildJsonArray{add(buildJsonObject{put("id","a");put("name",name);put("quantity",quantity)})})}
 @Test fun quantityUpdateUsesBaselineAndDurableKeys(){val batch=HouseholdWire.batch(doc(5),doc(3),8);assertEquals(-2,batch.getValue("quantityOperations").jsonArray.single().jsonObject.getValue("delta").jsonPrimitive.int);assertEquals(5,batch.getValue("inventory").jsonArray.single().jsonObject.getValue("quantity").jsonPrimitive.int);assertEquals(batch,Json.parseToJsonElement(batch.toString()))}
 @Test fun acknowledgeDoesNotReapplyAlreadySentQuantity(){val merged=HouseholdWire.merge(doc(3),doc(3),doc(2));assertEquals(2,HouseholdWire.rows(merged,"inventory").getValue("a").getValue("quantity").jsonPrimitive.int)}
 @Test fun editsMadeDuringFlightAreRetained(){val merged=HouseholdWire.merge(doc(3),doc(3,"Local edit"),doc(2));assertEquals("Local edit",HouseholdWire.rows(merged,"inventory").getValue("a").getValue("name").jsonPrimitive.content)}
 @Test fun unchangedRecordHonorsServerTombstone(){val remote=buildJsonObject{put("inventory",JsonArray(emptyList()));put("invDeleted",buildJsonArray{add("a")})};assertTrue(HouseholdWire.rows(HouseholdWire.merge(doc(5),doc(5),remote),"inventory").isEmpty())}
 @Test fun batchLimitKeepsUnsentRecordsInNextDiff(){val base=buildJsonObject{put("inventory",JsonArray(emptyList()))};val current=buildJsonObject{put("inventory",buildJsonArray{repeat(201){i->add(buildJsonObject{put("id","item-$i");put("name","Milk");put("quantity",1)})}})};val first=HouseholdWire.batch(base,current,1);assertEquals(200,first.getValue("operations").jsonArray.size);val snapshot=HouseholdWire.sentSnapshot(base,current,first);assertEquals(1,HouseholdWire.batch(snapshot,current,2).getValue("operations").jsonArray.size)}
 @Test fun membershipJournalDoesNotExport(){val state=com.sowens.stocked.data.KitchenState(extra=buildJsonObject{put("_androidHousehold",buildJsonObject{put("code","PRIVATE")});put("iosSetting",true)});val exported=com.sowens.stocked.data.BackupCodec.export(state);assertFalse(exported.contains("PRIVATE"));assertTrue(exported.contains("iosSetting"))}
 @Test fun offlineDeleteSurvivesRemotePull(){val empty=buildJsonObject{put("inventory",JsonArray(emptyList()))};val merged=HouseholdWire.merge(doc(5),empty,doc(7));assertTrue(HouseholdWire.rows(merged,"inventory").isEmpty());assertEquals("delete",HouseholdWire.batch(doc(5),empty,1).getValue("operations").jsonArray.single().jsonObject.getValue("operationType").jsonPrimitive.content)}
 @Test fun androidZonesUseReleasedIOSWireKey(){
  for(zone in listOf("Fridge","Freezer","Pantry","Staples")) {
   val state=com.sowens.stocked.data.KitchenState(inventory=listOf(com.sowens.stocked.data.InventoryItem(name="Milk",storageCategory=zone)))
   val row=HouseholdWire.document(state).getValue("inventory").jsonArray.single().jsonObject
   assertEquals(zone,row.getValue("zone").jsonPrimitive.content);assertFalse(row.containsKey("storageCategory"))
  }
 }
 @Test fun iosZoneImportsWithoutChangingStorageOrUnknownMetadata(){
  val id="00000000-0000-0000-0000-000000000001"
  val remote=buildJsonObject{put("inventory",buildJsonArray{add(buildJsonObject{put("id",id);put("name","Milk");put("quantity",2);put("zone","Fridge");put("futureField","preserved")})})}
  val kitchen=HouseholdWire.kitchen(remote,com.sowens.stocked.data.KitchenState())
  assertEquals("Fridge",kitchen.inventory.single().storageCategory)
  val roundTrip=HouseholdWire.document(kitchen).getValue("inventory").jsonArray.single().jsonObject
  assertEquals("Fridge",roundTrip.getValue("zone").jsonPrimitive.content);assertEquals("preserved",roundTrip.getValue("futureField").jsonPrimitive.content)
 }
 @Test fun androidRecipesAndMealsSupplyRequiredIOSCodableFields(){
  val state=com.sowens.stocked.data.KitchenState(userRecipes=listOf(com.sowens.stocked.data.Recipe(title="Soup",ingredients=listOf(com.sowens.stocked.data.Ingredient(name="Beans")),instructions=listOf("Cook"),updatedAt=1780000000000.0)),planned=listOf(com.sowens.stocked.data.PlannedMeal(title="Soup")))
  val wire=HouseholdWire.document(state)
  val recipe=wire.getValue("userRecipes").jsonArray.single().jsonObject
  assertEquals("Medium",recipe.getValue("difficulty").jsonPrimitive.content)
  assertEquals("unspecified",recipe.getValue("dishRole").jsonPrimitive.content)
  assertEquals(801692800.0,recipe.getValue("dateCreated").jsonPrimitive.double,0.01)
  assertFalse(recipe.getValue("ingredients").jsonArray.single().jsonObject.getValue("isOptional").jsonPrimitive.boolean)
  val meal=wire.getValue("plannedMeals").jsonArray.single().jsonObject
  assertFalse(meal.getValue("isBuilding").jsonPrimitive.boolean);assertEquals("none",meal.getValue("cookAheadStatus").jsonPrimitive.content)
 }
 @Test fun byteBoundedBatchKeepsUnsentRowsForNextBatch(){
  val base=buildJsonObject{put("userRecipes",JsonArray(emptyList()))}
  val current=buildJsonObject{put("userRecipes",buildJsonArray{repeat(3){i->add(buildJsonObject{put("id","recipe-$i");put("title","Soup");put("notes","🍲".repeat(200000))})}})}
  val batch=HouseholdWire.batch(base,current,1)
  assertEquals(2,batch.getValue("operations").jsonArray.size)
  assertTrue(batch.toString().toByteArray(Charsets.UTF_8).size<=HouseholdWire.MAX_BATCH_BYTES)
  val snapshot=HouseholdWire.sentSnapshot(base,current,batch)
  assertEquals(1,HouseholdWire.batch(snapshot,current,2).getValue("operations").jsonArray.size)
  assertEquals(batch,Json.parseToJsonElement(batch.toString()))
 }
 @Test fun oversizedSingleRecordFailsBeforeFreezingOrLosingData(){
  val empty=JsonObject(emptyMap());val large=buildJsonObject{put("userRecipes",buildJsonArray{add(buildJsonObject{put("id","huge");put("title","Soup");put("notes","x".repeat(HouseholdWire.MAX_BATCH_BYTES))})})}
  val error=runCatching{HouseholdWire.batch(empty,large,1)}.exceptionOrNull()
  assertTrue(error is IllegalArgumentException);assertTrue(error!!.message!!.contains("Local data has been retained"))
  assertEquals(1,HouseholdWire.rows(large,"userRecipes").size)
 }

}
