export function offlineSafetyReserve(reorderLevel){return Math.max(1,Number(reorderLevel||0)*.25)}
export function canQueueOfflineItem(stock,quantity,reorderLevel){return Number(quantity)>0&&Number(stock)-Number(quantity)>=offlineSafetyReserve(reorderLevel)}
export function isRetryableNetworkError(message){return /fetch|network|connection/i.test(String(message||""))}
