## created on Compound v2
- it uses layer0 protocol where each chain has a l0 endpoint(eid)
##
- this protocol is cross chain
- How does it verify authenticity?
- How does it manage message ordering?
- How does is manage message failure?
- Does it have checks for fake messages from other chains?
- How can I break atomicity?

### Critical Flow Example:
Chain A: User calls borrowCrossChain() → Sends message to Chain B   
Chain B: Receives message → Executes borrow → Sends confirmation back   
Chain A: Updates local state based on confirmation   


### Audit Checklist for LayerZero
#### ✅ Message Validation

 Verify sender authenticity   
 Check message replay protection  
 Validate payload structure  
#### ✅ State Consistency

 Handle out-of-order messages  
 Verify cross-chain state sync   
 Test failure scenarios   
#### ✅ Access Control

 Verify only authorized endpoints can send messages   
 Check admin controls for endpoint management    
#### ✅ Economic Security 
 Test gas payment mechanisms  
 Verify fee handling  
 Check for DoS vectors  
 