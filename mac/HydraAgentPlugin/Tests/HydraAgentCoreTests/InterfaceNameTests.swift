import Testing
@testable import HydraAgentCore

@Test func interfaceNamesAcceptBSDNamesOnly() {
    #expect(NetworkInterfaces.isValidName("en0"))
    #expect(NetworkInterfaces.isValidName("bridge100"))
    #expect(NetworkInterfaces.isValidName("  en1  "))
    #expect(!NetworkInterfaces.isValidName(""))
    #expect(!NetworkInterfaces.isValidName("en0; rm"))
    #expect(!NetworkInterfaces.isValidName("en0 en1"))
    #expect(!NetworkInterfaces.isValidName("-n"))
    #expect(!NetworkInterfaces.isValidName("1en"))
}
