package app.lumiq.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/** Large title with a round close (or back) button. */
@Composable
fun SheetHeader(title: String, onClose: () -> Unit, closeGlyph: Glyph = Glyph.Close) {
    Row(
        Modifier.fillMaxWidth().statusBarsPadding().padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (closeGlyph == Glyph.Back) {
            RoundGlyphButton(Glyph.Back, "Back", onClose)
            Spacer(Modifier.width(14.dp))
        }
        Text(title, fontSize = 30.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.6).sp, color = Palette.text, modifier = Modifier.weight(1f))
        if (closeGlyph != Glyph.Back) RoundGlyphButton(closeGlyph, "Close", onClose)
    }
}

/** Frosted round icon button. */
@Composable
fun RoundGlyphButton(glyph: Glyph, label: String, onClick: () -> Unit, tint: Color = Palette.text, size: Int = 38, background: Color = Palette.glass) {
    Box(
        Modifier.size(size.dp).clip(CircleShape).background(background).border(1.dp, Palette.stroke, CircleShape)
            .clickable(onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { GlyphIcon(glyph, tint, (size * 0.42f).dp) }
}

/** Small section label above a group of rows. */
@Composable
fun Eyebrow(text: String) {
    Text(text, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Palette.muted, letterSpacing = 0.1.sp)
}

/** A titled group of rows on one rounded card. */
@Composable
fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.padding(start = 6.dp)) { Eyebrow(title) }
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Palette.panel).border(1.dp, Palette.stroke, RoundedCornerShape(18.dp)),
            content = content,
        )
    }
}

/** Rounded tile behind a row's icon. */
@Composable
fun GlyphTile(glyph: Glyph, tint: Color = Palette.accent) {
    Box(Modifier.size(32.dp).clip(RoundedCornerShape(9.dp)).background(tint.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
        GlyphIcon(glyph, tint, 17.dp)
    }
}

@Composable
private fun RowScope.RowText(title: String, subtitle: String?, color: Color) {
    Column(Modifier.weight(1f).padding(vertical = 2.dp)) {
        Text(title, color = color, fontSize = 16.sp, fontWeight = FontWeight.Medium)
        if (subtitle != null) Text(subtitle, color = Palette.muted, fontSize = 13.sp, lineHeight = 17.sp)
    }
}

@Composable
fun SettingToggle(title: String, value: Boolean, subtitle: String? = null, glyph: Glyph? = null, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable { onChange(!value) }.heightIn(min = 58.dp).padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (glyph != null) GlyphTile(glyph)
        RowText(title, subtitle, Palette.text)
        LumiqSwitch(value, onChange)
    }
}

@Composable
fun LumiqSwitch(checked: Boolean, onChange: (Boolean) -> Unit) {
    Switch(
        checked = checked, onCheckedChange = onChange,
        colors = SwitchDefaults.colors(
            checkedTrackColor = Palette.accentStrong, checkedThumbColor = Color.White, checkedBorderColor = Color.Transparent,
            uncheckedTrackColor = Color.White.copy(alpha = 0.10f), uncheckedThumbColor = Palette.muted, uncheckedBorderColor = Color.Transparent,
        ),
    )
}

@Composable
fun NavigationRow(title: String, value: String? = null, color: Color = Palette.text, glyph: Glyph? = null, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 56.dp).padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (glyph != null) GlyphTile(glyph)
        RowText(title, null, color)
        if (value != null) Text(value, color = Palette.muted, fontSize = 14.sp)
        GlyphIcon(Glyph.Back, Palette.muted.copy(alpha = 0.7f), 12.dp, rotation = 180f)
    }
}

/** A read-only row (label and value). */
@Composable
fun ValueRow(title: String, value: String, glyph: Glyph? = null) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (glyph != null) GlyphTile(glyph)
        RowText(title, null, Palette.text)
        Text(value, color = Palette.muted, fontSize = 14.sp)
    }
}

/** Divider between rows; [indented] lines it up with the text of rows that have an icon tile. */
@Composable
fun RowSeparator(indented: Boolean = true) =
    HorizontalDivider(Modifier.padding(start = if (indented) 58.dp else 14.dp), color = Palette.stroke)

@Composable
fun FootNote(text: String) {
    Text(text, color = Palette.muted, fontSize = 13.sp, lineHeight = 18.sp, modifier = Modifier.padding(horizontal = 6.dp))
}

/** Frosted capsule used on the viewfinder. */
@Composable
fun Pill(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(
        modifier.clip(RoundedCornerShape(50)).background(Color(0xCC111118)).border(1.dp, Palette.stroke, RoundedCornerShape(50))
            .padding(horizontal = 12.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) { content() }
}

// region Buttons

/** Filled brand button. */
@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, destructive: Boolean = false) {
    val fill = if (destructive) Palette.danger else Palette.accent
    Box(
        modifier.heightIn(min = 46.dp).clip(RoundedCornerShape(50)).background(if (enabled) fill else fill.copy(alpha = 0.35f))
            .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 20.dp),
        contentAlignment = Alignment.Center,
    ) { Text(text, color = Color(0xFF14102E), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center) }
}

/** Quiet button on a frosted capsule. */
@Composable
fun SecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier.heightIn(min = 46.dp).clip(RoundedCornerShape(50)).background(Palette.glass).clickable(onClick = onClick).padding(horizontal = 20.dp),
        contentAlignment = Alignment.Center,
    ) { Text(text, color = Palette.text, fontSize = 15.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center) }
}

// endregion

// region Dialog

/**
 * Lumiq's own dialog: a dark rounded card drawn by the app (not the system dialog, which some
 * phones recolor with their own dark mode). Buttons stack full width, primary on top.
 */
@Composable
fun LumiqDialog(
    title: String,
    onDismiss: () -> Unit,
    primary: Pair<String, () -> Unit>?,
    secondary: Pair<String, () -> Unit>? = null,
    destructive: Boolean = false,
    dismissible: Boolean = true,
    closeOnOutsideTap: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    Dialog(onDismiss, DialogProperties(dismissOnBackPress = dismissible, dismissOnClickOutside = dismissible && closeOnOutsideTap)) {
        DialogCard(title, primary, secondary, destructive, content)
    }
}

/** The card inside [LumiqDialog]; separate so it can also be previewed without a window. */
@Composable
fun DialogCard(
    title: String,
    primary: Pair<String, () -> Unit>?,
    secondary: Pair<String, () -> Unit>? = null,
    destructive: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        Modifier.widthIn(max = 420.dp).fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(Palette.raised)
            .border(1.dp, Palette.stroke, RoundedCornerShape(28.dp)).padding(22.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text(title, color = Palette.text, fontSize = 21.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.3).sp)
        Column(verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
        Spacer(Modifier.height(2.dp))
        if (primary != null) PrimaryButton(primary.first, primary.second, Modifier.fillMaxWidth(), destructive = destructive)
        if (secondary != null) SecondaryButton(secondary.first, secondary.second, Modifier.fillMaxWidth())
    }
}

/** Body text for dialogs. */
@Composable
fun DialogText(text: String, color: Color = Palette.muted) = Text(text, color = color, fontSize = 15.sp, lineHeight = 21.sp)

// endregion

// region Menu

private val MenuShape = RoundedCornerShape(20.dp)

/** Lumiq-styled dropdown menu (dark card, rounded, hairline edge). */
@Composable
fun LumiqMenu(expanded: Boolean, onDismiss: () -> Unit, offset: DpOffset = DpOffset(0.dp, 6.dp), content: @Composable ColumnScope.() -> Unit) {
    DropdownMenu(
        expanded, onDismiss, offset = offset, shape = MenuShape, containerColor = Palette.raised,
        tonalElevation = 0.dp, shadowElevation = 12.dp, border = androidx.compose.foundation.BorderStroke(1.dp, Palette.stroke),
        modifier = Modifier.widthIn(min = 220.dp),
    ) { Column(Modifier.padding(vertical = 2.dp), content = content) }
}

/** Preview of [LumiqMenu]'s card without a popup window. */
@Composable
fun MenuCard(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.width(240.dp).clip(MenuShape).background(Palette.raised).border(1.dp, Palette.stroke, MenuShape).padding(vertical = 10.dp),
        content = content,
    )
}

@Composable
fun MenuHeader(text: String) {
    Text(text, color = Palette.muted, fontSize = 12.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp, bottom = 4.dp))
}

/** A menu row; [checked] shows an on/off state on the right, [selected] highlights a single choice. */
@Composable
fun MenuRow(text: String, glyph: Glyph? = null, checked: Boolean? = null, selected: Boolean = false, leading: (@Composable () -> Unit)? = null, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 46.dp).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        val tint = if (selected) Palette.accent else Palette.text
        when {
            leading != null -> leading()
            glyph != null -> GlyphIcon(glyph, if (selected) Palette.accent else Palette.muted, 19.dp)
        }
        Text(text, color = tint, fontSize = 15.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal, modifier = Modifier.weight(1f))
        if (checked != null) {
            Box(
                Modifier.size(20.dp).clip(CircleShape).background(if (checked) Palette.accentStrong else Color.Transparent)
                    .border(1.5.dp, if (checked) Palette.accentStrong else Palette.muted.copy(alpha = 0.6f), CircleShape),
                contentAlignment = Alignment.Center,
            ) { if (checked) GlyphIcon(Glyph.Tick, Color.White, 13.dp) }
        }
        if (selected && checked == null) Box(Modifier.size(7.dp).clip(CircleShape).background(Palette.accent))
    }
}

@Composable
fun MenuDivider() = HorizontalDivider(Modifier.padding(vertical = 4.dp), color = Palette.stroke)

// endregion
