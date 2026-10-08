package com.sowens.stocked.data
import org.junit.Assert.*
import org.junit.Test
class LocalInventoryBatchTest {
 @Test fun batchPreservesPriorDataAndStampsOneTransaction() {
  val original=InventoryItem(name="Existing",quantity=3)
  val state=KitchenState(inventory=listOf(original))
  val incoming=listOf(InventoryItem(name="  Apples  "),InventoryItem(name="Beans"))
  val next=LocalInventoryBatch.apply(state,incoming,42.0)
  assertEquals(original,next.inventory.first());assertEquals(3,next.inventory.size)
  assertEquals("Apples",next.inventory[1].name);assertTrue(next.inventory.drop(1).all{it.updatedAt==42.0})
 }
 @Test fun invalidBatchDoesNotPartiallyModifyOriginal() {
  val state=KitchenState(inventory=listOf(InventoryItem(name="Existing")))
  assertTrue(runCatching{LocalInventoryBatch.apply(state,listOf(InventoryItem(name="Valid"),InventoryItem(name="")),42.0)}.isFailure)
  assertEquals(1,state.inventory.size)
 }
 @Test fun existingOrDuplicateIdsAreRejected() {
  val original=InventoryItem(name="Eggs")
  assertTrue(runCatching{LocalInventoryBatch.apply(KitchenState(inventory=listOf(original)),listOf(original.copy(name="Milk")),42.0)}.isFailure)
  assertTrue(runCatching{LocalInventoryBatch.apply(KitchenState(),listOf(original,original),42.0)}.isFailure)
 }
}
