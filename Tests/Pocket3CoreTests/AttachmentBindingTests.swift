import Testing
@testable import Pocket3Core

@Test func attachmentBindingCannotFollowAReusedUSBPort() throws {
    var binding = UVCAttachmentBinding()
    try binding.validate(registryID: "attachment-a", bootSessionID: "boot-a")
    try binding.validate(registryID: "attachment-a", bootSessionID: "boot-a")
    #expect(throws: BridgeFailure.self) { try binding.validate(registryID: "attachment-b", bootSessionID: "boot-a") }
    #expect(throws: BridgeFailure.self) { try binding.validate(registryID: "attachment-a", bootSessionID: "boot-b") }
    #expect(binding.registryID == "attachment-a")
}

@Test func missingIdentityDoesNotAuthorizeUSBWrites() throws {
    var binding = UVCAttachmentBinding()
    #expect(throws: BridgeFailure.self) { try binding.validate(registryID: nil, bootSessionID: "boot-a") }
    #expect(throws: BridgeFailure.self) { try binding.validate(registryID: "", bootSessionID: "boot-a") }
    #expect(binding.registryID == nil)
    try binding.validate(registryID: "attachment-a", bootSessionID: "boot-a")
    #expect(throws: BridgeFailure.self) { try binding.validate(registryID: "attachment-a", bootSessionID: nil) }
    #expect(binding.registryID == "attachment-a")
}
