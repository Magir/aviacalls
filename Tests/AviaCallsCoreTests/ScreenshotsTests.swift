import Testing
@testable import AviaCallsCore

@Suite struct ScreenshotsTests {
    // кадры как маленькие серые картинки: один байт на пиксель
    let slide = [UInt8](repeating: 40, count: 64)
    var slideWithCursor: [UInt8] { var s = slide; s[10] = 200; return s }   // сдвинулся курсор
    let otherSlide = [UInt8](repeating: 180, count: 64)
    var video: [UInt8] { (0..<64).map { UInt8($0 * 4 % 256) } }

    @Test func savesFirstStaticFrame() {
        var d = Screenshots.Detector()
        let r1 = d.consider(slide); #expect(!r1)          // первый кадр: ещё не знаем, статичен ли
        let r2 = d.consider(slide); #expect(r2)           // второй такой же — статичный и новый, сохраняем
    }

    @Test func ignoresLiveVideo() {
        var d = Screenshots.Detector()
        _ = d.consider(video)
        let r3 = d.consider(otherSlide); #expect(!r3)     // кадр изменился относительно предыдущего — это видео, не слайд
        let r4 = d.consider(video); #expect(!r4)
    }

    @Test func doesNotSaveSameSlideTwice() {
        var d = Screenshots.Detector()
        _ = d.consider(slide); _ = d.consider(slide)
        let r5 = d.consider(slide); #expect(!r5)
        let r6 = d.consider(slideWithCursor); #expect(!r6)   // курсор поехал — тот же слайд
        let r7 = d.consider(slideWithCursor); #expect(!r7)
    }

    @Test func savesWhenSlideChanges() {
        var d = Screenshots.Detector()
        _ = d.consider(slide); _ = d.consider(slide)
        _ = d.consider(otherSlide)            // переключили слайд: сначала кадр «меняется»
        let r8 = d.consider(otherSlide); #expect(r8)       // устоялся — сохраняем
    }

    @Test func meanDifference() {
        #expect(Screenshots.difference(slide, slide) == 0)
        #expect(Screenshots.difference(slide, otherSlide) == 140)
        #expect(Screenshots.difference(slide, [UInt8](repeating: 40, count: 10)) == 255)   // разный размер — считаем другим
    }
}
