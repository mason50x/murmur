import FluidAudio
import Testing

@testable import Murmur

@Suite("SmartFormat")
struct SmartFormatTests {
    @Test func standaloneBecomesASentence() {
        #expect(SmartFormat.apply("hello world", before: nil, after: nil) == "Hello world.")
        #expect(SmartFormat.apply("is it ready?", before: nil, after: nil) == "Is it ready?")
    }

    @Test func emptyFieldGetsASentence() {
        #expect(SmartFormat.apply("see you soon", before: "", after: "") == "See you soon.")
    }

    @Test func midSentenceLowercasesCommonWordsAndSpaces() {
        #expect(SmartFormat.apply("The demo moved.", before: "I heard", after: "") == " the demo moved.")
    }

    @Test func keepsNamesAndIUppercase() {
        #expect(SmartFormat.apply("Sam agreed.", before: "and then", after: "") == " Sam agreed.")
        #expect(SmartFormat.apply("I think so.", before: "and", after: "") == " I think so.")
    }

    @Test func insertingBeforeTextDropsThePeriod() {
        #expect(SmartFormat.apply("Really", before: "", after: "good idea") == "Really ")
        #expect(SmartFormat.apply("Maybe.", before: "We can ", after: "tomorrow") == "maybe ")
    }

    @Test func listsDontGetATrailingPeriod() {
        let list = "Plan:\n\n1. Move the demo\n2. Ship it"
        #expect(SmartFormat.apply(list, before: nil, after: nil) == list)
    }

    @Test func layoutOnlyOnAnEmptyLine() {
        #expect(SmartFormat.allowsLayout(before: "Notes\n", after: ""))
        #expect(!SmartFormat.allowsLayout(before: "Notes: ", after: ""))
        #expect(!SmartFormat.allowsLayout(before: "", after: "already here"))
    }
}

@Suite("Layout")
struct LayoutTests {
    @Test func spokenOrdinalsBecomeANumberedList() throws {
        let text = "Hey Sam, first, move the demo to Thursday. Second, finish the onboarding flow. Thanks, Mason."
        let laid = try #require(Layout.format(text, words: []))
        #expect(laid.contains("1. Move the demo to Thursday."))
        #expect(laid.contains("2. Finish the onboarding flow."))
        #expect(laid.hasPrefix("Hey Sam,"))
    }

    @Test func plainProseIsLeftAlone() {
        #expect(Layout.format("Let's grab lunch tomorrow.", words: []) == nil)
    }
}

@Suite("Model recommendation")
struct ModelTests {
    @Test func bigMacsGetTheMostAccurateModel() {
        #expect(DeviceProfile(chip: "Apple M4 Pro", memoryGB: 24, freeDiskGB: 200).recommended == .unified)
        #expect(DeviceProfile(chip: "Apple M1", memoryGB: 16, freeDiskGB: 50).recommended == .unified)
    }

    @Test func eightGigabyteMacsGetTheLightModel() {
        #expect(DeviceProfile(chip: "Apple M1", memoryGB: 8, freeDiskGB: 200).recommended == .phonon2)
    }

    @Test func aNearlyFullDiskGetsTheLightModel() {
        #expect(DeviceProfile(chip: "Apple M3 Max", memoryGB: 64, freeDiskGB: 1.2).recommended == .phonon2)
    }

    @Test func modelsLiveInFluidAudiosCache() {
        #expect(SpeechModel.unified.cacheDirectory.path.hasSuffix("FluidAudio/Models/parakeet-unified-en-0.6b"))
        #expect(SpeechModel.phonon2.cacheDirectory.path.hasSuffix("FluidAudio/Models/phonon-2"))
    }
}
