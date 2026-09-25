import Foundation
import Testing
import HDMCore
import HDMTestSupport

@Test func versionIsSet() {
    #expect(!HDMCoreInfo.version.isEmpty)
}

@Test func testDataIsDeterministic() {
    #expect(TestData.random(count: 1000) == TestData.random(count: 1000))
    #expect(TestData.random(count: 1000, seed: 1) != TestData.random(count: 1000, seed: 2))
    #expect(TestData.random(count: 0).isEmpty)
    #expect(TestData.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}
