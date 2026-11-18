package app.lumiq.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Large title with a round close button, like the iPhone sheets. */
@Composable
fun SheetHeader(title: String, onClose: () -> Unit, closeGlyph: Glyph = Glyph.Close) {
    Row(
        Modifier.fillMaxWidth().statusBarsPadding().padding(start = 22.dp, end = 22.dp, top = 16.dp, bottom = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (closeGlyph == Glyph.Back) {
            RoundGlyphButton(Glyph.Back, "Back", onClose)
            Spacer(Modifier.width(12.dp))
        }
        Text(title, fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Color.White, modifier = Modifier.weight(1f))
        if (closeGlyph != Glyph.Back) RoundGlyphButton(closeGlyph, "Close", onClose)
    }
}

@Composable
fun RoundGlyphButton(glyph: Glyph, label: String, onClick: () -> Unit) {
    Box(
        Modifier.size(34.dp).clip(CircleShape).background(Palette.panel).clickable(onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { GlyphIcon(glyph, Color.White, 16.dp) }
}

@Composable
fun Eyebrow(text: String) {
    Text(text.uppercase(), fontFamily = FontFamily.Monospace, fontSize = 11.sp, letterSpacing = 2.sp, fontWeight = FontWeight.Medium, color = Palette.muted)
}

@Composable
fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.padding(start = 15.dp)) { Eyebrow(title) }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Palette.panel), content = content)
    }
}

@Composable
fun SettingToggle(title: String, value: Boolean, subtitle: String? = null, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable { onChange(!value) }.heightIn(min = 48.dp).padding(horizontal = 15.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = Color.White, fontSize = 16.sp)
            if (subtitle != null) Text(subtitle, color = Palette.muted, fontSize = 12.sp)
        }
        Switch(
            checked = value, onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = Palette.yellow, checkedThumbColor = Color.Black),
        )
    }
}

@Composable
fun NavigationRow(title: String, value: String? = null, color: Color = Color.White, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).height(48.dp).padding(horizontal = 15.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, color = color, fontSize = 16.sp, modifier = Modifier.weight(1f))
        if (value != null) Text(value, color = Palette.muted, fontSize = 14.sp, modifier = Modifier.padding(end = 8.dp))
        GlyphIcon(Glyph.Back, Palette.muted, 12.dp, rotation = 180f)
    }
}

@Composable
fun RowSeparator() = HorizontalDivider(Modifier.padding(start = 15.dp), color = Color.White.copy(alpha = 0.08f))

@Composable
fun FootNote(text: String) {
    Text(text, color = Palette.muted, fontSize = 12.sp, lineHeight = 17.sp, modifier = Modifier.padding(horizontal = 15.dp))
}

/** Dark capsule label used on the viewfinder. */
@Composable
fun Pill(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(
        modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.62f)).padding(horizontal = 12.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) { content() }
}
