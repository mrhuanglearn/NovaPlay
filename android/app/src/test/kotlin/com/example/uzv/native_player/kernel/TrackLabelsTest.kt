package com.example.uzv.native_player.kernel

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class TrackLabelsTest {
    @Test fun mimeFromExtensionIgnoresQueryAndFragment() {
        assertEquals(TrackLabels.SUBRIP, TrackLabels.subtitleMime("https://x/a.SRT?token=1#t", null))
        assertEquals(TrackLabels.VTT, TrackLabels.subtitleMime("https://x/a.vtt", "text/x-ssa")) // extension wins
        assertEquals(TrackLabels.SSA, TrackLabels.subtitleMime("https://x/a.ass", null))
        assertEquals(TrackLabels.SSA, TrackLabels.subtitleMime("https://x/a.ssa", null))
        assertEquals(TrackLabels.TTML, TrackLabels.subtitleMime("https://x/a.ttml", null))
    }

    @Test fun mimeFallsBackToDeclaredTypeAndDropsUnknown() {
        assertEquals(TrackLabels.SUBRIP, TrackLabels.subtitleMime("https://x/sub?id=3", "srt"))
        assertEquals(TrackLabels.SUBRIP, TrackLabels.subtitleMime("https://x/sub", "application/x-subrip"))
        assertEquals(TrackLabels.VTT, TrackLabels.subtitleMime("https://x/sub", "text/vtt"))
        assertEquals(TrackLabels.SSA, TrackLabels.subtitleMime("https://x/sub", "ass"))
        assertNull(TrackLabels.subtitleMime("https://x/sub", null))
        assertNull(TrackLabels.subtitleMime("https://x/sub", "image/png"))
    }

    @Test fun languagesAreNormalised() {
        assertEquals("zh", TrackLabels.primaryLanguage("zh-CN"))
        assertEquals("zh", TrackLabels.primaryLanguage("zh_TW"))
        assertEquals("zh", TrackLabels.primaryLanguage("chi"))
        assertEquals("en", TrackLabels.primaryLanguage("ENG"))
        assertNull(TrackLabels.primaryLanguage("und"))
        assertNull(TrackLabels.primaryLanguage(" "))
        assertNull(TrackLabels.primaryLanguage(null))
        assertEquals("English", TrackLabels.languageName("en-US"))
    }

    @Test fun textLabelsUseWhatTheTrackSays() {
        assertEquals("Forced · English", TrackLabels.textLabel("Forced", "en", 0))
        assertEquals("English", TrackLabels.textLabel("English", "en", 0)) // no duplicate
        assertEquals("English", TrackLabels.textLabel(null, "en", 0))
        assertEquals("Subtitle 3", TrackLabels.textLabel(null, null, 2))
        assertEquals("Subtitle 1", TrackLabels.textLabel("  ", "und", 0))
    }

    @Test fun videoLabels() {
        assertEquals("1080p · 4.5 Mbps", TrackLabels.videoLabel(1080, 4_500_000, 0))
        assertEquals("720p · 800 kbps", TrackLabels.videoLabel(720, 800_000, 1))
        assertEquals("720p", TrackLabels.videoLabel(720, 0, 1))
        assertEquals("2.0 Mbps", TrackLabels.videoLabel(0, 2_000_000, 0))
        assertEquals("Track 4", TrackLabels.videoLabel(0, 0, 3))
    }

    private val labels = listOf<String?>("English", "Chinese (Simplified)", null)
    private val langs = listOf<String?>("en", "zh-Hans", null)
    private val flags = listOf(false, false, true)

    @Test fun defaultTextLabelBeatsLanguage() {
        // the user picked the English track earlier, but the preferred language says Chinese
        assertEquals(0, TrackLabels.chooseDefaultText(labels, langs, flags, "english", "zh-CN"))
    }

    @Test fun defaultTextFallsThroughToLanguageWhenNoLabelMatches() {
        assertEquals(1, TrackLabels.chooseDefaultText(labels, langs, flags, "Japanese", "zh-CN"))
        assertEquals(1, TrackLabels.chooseDefaultText(labels, langs, flags, null, "zh"))
    }

    @Test fun defaultTextFallsThroughToDefaultFlag() {
        assertEquals(2, TrackLabels.chooseDefaultText(labels, langs, flags, null, null))
        assertEquals(2, TrackLabels.chooseDefaultText(labels, langs, flags, "Nope", "ja"))
        assertEquals(-1, TrackLabels.chooseDefaultText(labels, langs, listOf(false, false, false), null, null))
        assertEquals(-1, TrackLabels.chooseDefaultText(emptyList(), emptyList(), emptyList(), "x", "en"))
    }

    @Test fun defaultTextIgnoresBlankPreferences() {
        assertEquals(2, TrackLabels.chooseDefaultText(labels, langs, flags, "  ", " "))
    }

    @Test fun fontLookupIsCaseInsensitiveAndExtensionRestricted() {
        val dir = Files.createTempDirectory("fonts").toFile()
        try {
            File(dir, "NotoSansSC.otf").writeText("x")
            File(dir, "readme.txt").writeText("x")
            File(dir, "Other.ttf").writeText("x")
            assertNotNull(TrackLabels.findFont(dir.path, "notosanssc"))
            assertEquals("Other.ttf", TrackLabels.findFont(dir.path, "Other")?.name)
            assertNull(TrackLabels.findFont(dir.path, "readme"))
            assertNull(TrackLabels.findFont(dir.path, "missing"))
            assertNull(TrackLabels.findFont("${dir.path}/nope", "Other"))
            assertNull(TrackLabels.findFont(null, "Other"))
            assertNull(TrackLabels.findFont(dir.path, ""))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun audioLabelsCombineNameLanguageAndLayout() {
        assertEquals("Japanese \u00B7 stereo", TrackLabels.audioLabel(null, "ja", 2, 0))
        assertEquals("Commentary \u00B7 English \u00B7 5.1", TrackLabels.audioLabel("Commentary", "en", 6, 1))
        assertEquals("English \u00B7 mono", TrackLabels.audioLabel("English", "en", 1, 0)) // language not repeated
        assertEquals("Audio 3", TrackLabels.audioLabel(null, "und", 0, 2))
        assertEquals("Audio 1 \u00B7 7.1", TrackLabels.audioLabel(" ", null, 8, 0))
        assertEquals("Chinese \u00B7 3ch", TrackLabels.audioLabel(null, "zh", 3, 0))
    }

    @Test fun chooseAudioUsesLabelThenLanguageAndOtherwiseLeavesExoAlone() {
        val l = listOf<String?>("Japanese", "English", null)
        val g = listOf<String?>("ja", "en", "zh")
        assertEquals(1, TrackLabels.chooseAudio(l, g, "english", "ja")) // label beats language
        assertEquals(0, TrackLabels.chooseAudio(l, g, "Commentary", "ja")) // no label match: language
        assertEquals(2, TrackLabels.chooseAudio(l, g, null, "zh-CN"))
        assertEquals(-1, TrackLabels.chooseAudio(l, g, null, null)) // no preference at all: Exo decides
        assertEquals(-1, TrackLabels.chooseAudio(l, g, "x", "ko"))
    }
}
