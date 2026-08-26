import test from "node:test";
import assert from "node:assert/strict";
import {offlineSafetyReserve,canQueueOfflineItem,isRetryableNetworkError} from "../lib/retail-rules.js";

test("offline reserve is at least one unit",()=>{assert.equal(offlineSafetyReserve(0),1);assert.equal(offlineSafetyReserve(2),1)});
test("offline reserve uses 25 percent of reorder level",()=>assert.equal(offlineSafetyReserve(20),5));
test("offline sale preserves the safety reserve",()=>{assert.equal(canQueueOfflineItem(10,5,20),true);assert.equal(canQueueOfflineItem(10,6,20),false)});
test("offline sale rejects zero and negative quantities",()=>{assert.equal(canQueueOfflineItem(10,0,5),false);assert.equal(canQueueOfflineItem(10,-1,5),false)});
test("only connection-like errors are retryable offline",()=>{assert.equal(isRetryableNetworkError("Failed to fetch"),true);assert.equal(isRetryableNetworkError("Insufficient stock"),false)});
