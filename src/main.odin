package launcher

import rl "vendor:raylib"
import "core:os"
import "core:strings"
import "core:fmt"
import "core:path/filepath"
import "core:mem"

when ODIN_OS == .Linux {
    foreign import libc "system:c"
    foreign libc {
        fork :: proc() -> i32 ---
        execl :: proc(path: cstring, arg: cstring, #c_vararg args: ..cstring) -> i32 ---
        setsid :: proc() -> i32 ---
    }
}

App_Entry :: struct {
    name:        string,
    exec:        string,
    comment:     string,
    icon_name:   string,       // Icon name from .desktop file
    icon_path:   string,       // Resolved absolute path to icon
    texture:     rl.Texture2D, // Loaded texture
    icon_loaded: bool,         // Whether load was attempted
}

Icon_Config :: struct {
    theme_dirs:  [dynamic]string,  // Icon theme directories
    theme_chain: [dynamic]string,  // Theme inheritance chain
}

State :: struct {
    apps:            [dynamic]App_Entry,
    filtered:        [dynamic]^App_Entry,
    input:           [dynamic]u8,
    selected:        int,
    scroll_offset:   int,
    icon_config:     Icon_Config,
    placeholder_tex: rl.Texture2D,
}

VISIBLE_ITEMS :: 10
ITEM_HEIGHT :: 32
WIDTH :: 600
HEIGHT :: 400

// Icon constants
ICON_SIZE :: 24
ICON_PADDING :: 8
TEXT_X_OFFSET :: 40  // ICON_PADDING + ICON_SIZE + ICON_PADDING

main :: proc() {
    state: State
    state.apps = find_applications()
    defer delete(state.apps)
    defer delete(state.filtered)
    defer delete(state.input)

    // Initialize icon system
    home := os.get_env("HOME")
    append(&state.icon_config.theme_dirs, strings.concatenate({home, "/.local/share/icons"}))
    append(&state.icon_config.theme_dirs, "/usr/share/icons")
    append(&state.icon_config.theme_dirs, "/usr/local/share/icons")

    current_theme := get_current_icon_theme()
    defer delete(current_theme)
    state.icon_config.theme_chain = build_theme_chain(current_theme, state.icon_config.theme_dirs[:])

    // Initially show all apps
    filter_apps(&state, "")

    rl.SetConfigFlags({.WINDOW_UNDECORATED})
    rl.InitWindow(WIDTH, HEIGHT, "Launcher")
    rl.SetTargetFPS(60)

    // Create placeholder icon (must be after InitWindow)
    state.placeholder_tex = create_placeholder_icon()

    // Center window on screen
    monitor := rl.GetCurrentMonitor()
    mx := rl.GetMonitorWidth(monitor)
    my := rl.GetMonitorHeight(monitor)
    rl.SetWindowPosition((mx - WIDTH) / 2, (my - HEIGHT) / 2)

    for !rl.WindowShouldClose() {
        handle_input(&state)
        draw(&state)
    }

    // Cleanup icons
    for &app in state.apps {
        if app.texture.id != 0 && app.texture.id != state.placeholder_tex.id {
            rl.UnloadTexture(app.texture)
        }
        delete(app.icon_name)
        delete(app.icon_path)
    }
    rl.UnloadTexture(state.placeholder_tex)

    // Cleanup icon config
    for dir in state.icon_config.theme_dirs {
        delete(dir)
    }
    delete(state.icon_config.theme_dirs)
    for theme in state.icon_config.theme_chain {
        delete(theme)
    }
    delete(state.icon_config.theme_chain)

    rl.CloseWindow()
}

handle_input :: proc(state: ^State) {
    // Text input
    for {
        char := rl.GetCharPressed()
        if char == 0 do break
        if char >= 32 && char < 127 {
            append(&state.input, u8(char))
            filter_apps(state, string(state.input[:]))
            state.selected = 0
            state.scroll_offset = 0
        }
    }

    // Backspace
    if rl.IsKeyPressedRepeat(.BACKSPACE) || rl.IsKeyPressed(.BACKSPACE) {
        if len(state.input) > 0 {
            pop(&state.input)
            filter_apps(state, string(state.input[:]))
            state.selected = 0
            state.scroll_offset = 0
        }
    }

    // Navigation
    if rl.IsKeyPressedRepeat(.DOWN) || rl.IsKeyPressed(.DOWN) {
        state.selected = min(state.selected + 1, len(state.filtered) - 1)
        // Scroll if needed
        if state.selected >= state.scroll_offset + VISIBLE_ITEMS {
            state.scroll_offset = state.selected - VISIBLE_ITEMS + 1
        }
    }
    if rl.IsKeyPressedRepeat(.UP) || rl.IsKeyPressed(.UP) {
        state.selected = max(state.selected - 1, 0)
        if state.selected < state.scroll_offset {
            state.scroll_offset = state.selected
        }
    }

    // Launch on Enter
    if rl.IsKeyPressed(.ENTER) && len(state.filtered) > 0 {
        launch_app(state.filtered[state.selected])
        rl.CloseWindow()
    }

    // Escape to quit
    if rl.IsKeyPressed(.ESCAPE) {
        rl.CloseWindow()
    }
}

draw :: proc(state: ^State) {
    rl.BeginDrawing()
    rl.ClearBackground({30, 30, 35, 255})

    // Input box
    rl.DrawRectangle(10, 10, WIDTH - 20, 36, {45, 45, 50, 255})
    rl.DrawRectangleLines(10, 10, WIDTH - 20, 36, {80, 80, 90, 255})
    
    input_text := len(state.input) > 0 ? string(state.input[:]) : ""
    rl.DrawText(
        strings.clone_to_cstring(input_text),
        20, 18, 20, {220, 220, 220, 255},
    )
    
    // Cursor
    cursor_x := 20 + rl.MeasureText(strings.clone_to_cstring(input_text), 20)
    if int(rl.GetTime() * 2) % 2 == 0 {
        rl.DrawRectangle(cursor_x + 2, 16, 2, 24, {150, 150, 200, 255})
    }

    // Results list
    list_y : i32 = 56
    visible_end := min(state.scroll_offset + VISIBLE_ITEMS, len(state.filtered))
    
    for i in state.scroll_offset ..< visible_end {
        app := state.filtered[i]
        y := list_y + i32(i - state.scroll_offset) * ITEM_HEIGHT

        // Lazy load icon
        load_app_icon(app, &state.icon_config, state.placeholder_tex)

        // Highlight selected
        if i == state.selected {
            rl.DrawRectangle(10, y, WIDTH - 20, ITEM_HEIGHT - 2, {60, 60, 80, 255})
        }

        // Draw icon (centered vertically)
        icon_y := y + (ITEM_HEIGHT - ICON_SIZE) / 2
        if app.texture.id != 0 {
            src := rl.Rectangle{0, 0, f32(app.texture.width), f32(app.texture.height)}
            dst := rl.Rectangle{f32(10 + ICON_PADDING), f32(icon_y), ICON_SIZE, ICON_SIZE}
            rl.DrawTexturePro(app.texture, src, dst, {0, 0}, 0, rl.WHITE)
        }

        // Draw app name (shifted right for icon)
        rl.DrawText(
            strings.clone_to_cstring(app.name),
            10 + TEXT_X_OFFSET, y + 6, 18, {200, 200, 210, 255},
        )
    }

    // Scroll indicator
    if len(state.filtered) > VISIBLE_ITEMS {
        total := len(state.filtered)
        bar_height := max(i32(20), i32(HEIGHT - 60) * VISIBLE_ITEMS / i32(total))
        bar_y := 56 + i32(state.scroll_offset) * (HEIGHT - 60 - bar_height) / i32(total - VISIBLE_ITEMS)
        rl.DrawRectangle(WIDTH - 14, bar_y, 4, bar_height, {80, 80, 100, 255})
    }

    rl.EndDrawing()
}

filter_apps :: proc(state: ^State, query: string) {
    clear(&state.filtered)
    
    if len(query) == 0 {
        for &app in state.apps {
            append(&state.filtered, &app)
        }
        return
    }

    // Simple fuzzy match
    Scored :: struct {
        app:   ^App_Entry,
        score: int,
    }
    scored: [dynamic]Scored
    defer delete(scored)

    query_lower := strings.to_lower(query)
    defer delete(query_lower)

    for &app in state.apps {
        if score, ok := fuzzy_match(query_lower, app.name); ok {
            append(&scored, Scored{&app, score})
        }
    }

    // Sort by score (simple insertion sort)
    for i in 1 ..< len(scored) {
        j := i
        for j > 0 && scored[j].score > scored[j-1].score {
            scored[j], scored[j-1] = scored[j-1], scored[j]
            j -= 1
        }
    }

    for s in scored {
        append(&state.filtered, s.app)
    }
}

fuzzy_match :: proc(pattern, text: string) -> (score: int, matched: bool) {
    text_lower := strings.to_lower(text)
    defer delete(text_lower)

    pi := 0
    last_match := -1
    
    for ti := 0; ti < len(text_lower) && pi < len(pattern); ti += 1 {
        if text_lower[ti] == pattern[pi] {
            score += 10
            // Bonus for consecutive matches
            if last_match == ti - 1 do score += 5
            // Bonus for start of word
            if ti == 0 || text_lower[ti-1] == ' ' do score += 15
            last_match = ti
            pi += 1
        }
    }
    
    return score, pi == len(pattern)
}

find_applications :: proc() -> [dynamic]App_Entry {
    apps: [dynamic]App_Entry
    
    home := os.get_env("HOME")
    dirs := []string{
        "/usr/share/applications",
        "/usr/local/share/applications",
        strings.concatenate({home, "/.local/share/applications"}),
    }

    for dir in dirs {
        if !os.exists(dir) do continue
        
        handle, err := os.open(dir)
        if err != os.ERROR_NONE do continue
        defer os.close(handle)

        files, _ := os.read_dir(handle, -1)
        for file in files {
            if !strings.has_suffix(file.name, ".desktop") do continue
            
            full_path := filepath.join({dir, file.name})
            if app, ok := parse_desktop_file(full_path); ok {
                append(&apps, app)
            }
        }
    }

    return apps
}

parse_desktop_file :: proc(path: string) -> (App_Entry, bool) {
    data, ok := os.read_entire_file(path)
    if !ok do return {}, false
    defer delete(data)

    content := string(data)
    app: App_Entry
    in_desktop_entry := false

    for line in strings.split_lines_iterator(&content) {
        line := strings.trim_space(line)
        
        if line == "[Desktop Entry]" {
            in_desktop_entry = true
            continue
        }
        if strings.has_prefix(line, "[") && line != "[Desktop Entry]" {
            in_desktop_entry = false
            continue
        }
        
        if !in_desktop_entry do continue

        if strings.has_prefix(line, "Name=") {
            app.name = strings.clone(line[5:])
        } else if strings.has_prefix(line, "Exec=") {
            exec := line[5:]
            // Remove field codes like %f, %u, etc.
            exec_clean := strings.clone(exec)
            field_codes := [?]string{"%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%i", "%c", "%k"}
            for code in field_codes {
                exec_clean, _ = strings.replace_all(exec_clean, code, "")
            }
            app.exec = strings.trim_space(exec_clean)
        } else if strings.has_prefix(line, "NoDisplay=true") {
            return {}, false
        } else if strings.has_prefix(line, "Type=") && line != "Type=Application" {
            return {}, false
        } else if strings.has_prefix(line, "Icon=") {
            app.icon_name = strings.clone(line[5:])
        }
    }

    if len(app.name) > 0 && len(app.exec) > 0 {
        return app, true
    }
    return {}, false
}

launch_app :: proc(app: ^App_Entry) {
    // Fork and exec
    cstr := strings.clone_to_cstring(app.exec)

    when ODIN_OS == .Linux {
        pid := fork()
        if pid == 0 {
            // Child process
            setsid()  // Detach from terminal
            execl("/bin/sh", "sh", "-c", cstr, nil)
        }
    }
}

// ============================================================================
// Icon Support Functions
// ============================================================================

// Get current icon theme from GTK3 settings, fallback to hicolor
get_current_icon_theme :: proc() -> string {
    home := os.get_env("HOME")
    gtk3_path := strings.concatenate({home, "/.config/gtk-3.0/settings.ini"})
    defer delete(gtk3_path)

    data, ok := os.read_entire_file(gtk3_path)
    if !ok {
        return strings.clone("hicolor")
    }
    defer delete(data)

    content := string(data)
    for line in strings.split_lines_iterator(&content) {
        line := strings.trim_space(line)
        if strings.has_prefix(line, "gtk-icon-theme-name=") {
            return strings.clone(line[20:])
        }
    }

    return strings.clone("hicolor")
}

// Parse a theme's index.theme to get inherited themes
parse_theme_inherits :: proc(theme_name: string, base_dirs: []string) -> [dynamic]string {
    inherits: [dynamic]string

    for base_dir in base_dirs {
        index_path := strings.concatenate({base_dir, "/", theme_name, "/index.theme"})
        defer delete(index_path)

        data, ok := os.read_entire_file(index_path)
        if !ok do continue
        defer delete(data)

        content := string(data)
        for line in strings.split_lines_iterator(&content) {
            line := strings.trim_space(line)
            if strings.has_prefix(line, "Inherits=") {
                inherits_str := line[9:]
                parts := strings.split(inherits_str, ",")
                defer delete(parts)
                for part in parts {
                    append(&inherits, strings.clone(strings.trim_space(part)))
                }
                return inherits
            }
        }
    }

    return inherits
}

// Build the complete theme search order
build_theme_chain :: proc(start_theme: string, base_dirs: []string) -> [dynamic]string {
    chain: [dynamic]string
    visited: map[string]bool
    defer delete(visited)

    queue: [dynamic]string
    defer delete(queue)
    append(&queue, strings.clone(start_theme))

    for len(queue) > 0 {
        theme := queue[0]
        ordered_remove(&queue, 0)

        if theme in visited {
            delete(theme)
            continue
        }
        visited[theme] = true
        append(&chain, theme)

        inherits := parse_theme_inherits(theme, base_dirs)
        defer delete(inherits)
        for inh in inherits {
            if !(inh in visited) {
                append(&queue, strings.clone(inh))
            }
        }
    }

    // Ensure hicolor is always at the end as fallback
    if !("hicolor" in visited) {
        append(&chain, strings.clone("hicolor"))
    }

    return chain
}

// Resolve an icon name to an absolute PNG path
resolve_icon_path :: proc(icon_name: string, config: ^Icon_Config) -> string {
    if len(icon_name) == 0 do return ""

    // If icon_name is already an absolute path
    if icon_name[0] == '/' {
        if os.exists(icon_name) && strings.has_suffix(icon_name, ".png") {
            return strings.clone(icon_name)
        }
        // Try adding .png extension
        png_path := strings.concatenate({icon_name, ".png"})
        if os.exists(png_path) {
            return png_path
        }
        delete(png_path)
        return ""
    }

    // Icon sizes to search (prefer 32, then larger, then smaller)
    sizes := [?]string{"32x32", "48x48", "24x24", "64x64", "16x16", "scalable"}

    // Search through theme chain
    for theme in config.theme_chain {
        for base_dir in config.theme_dirs {
            for size in sizes {
                // Standard path: {base_dir}/{theme}/{size}/apps/{icon_name}.png
                path := strings.concatenate({base_dir, "/", theme, "/", size, "/apps/", icon_name, ".png"})
                if os.exists(path) {
                    return path
                }
                delete(path)
            }
        }
    }

    // Fallback: check /usr/share/pixmaps
    pixmaps_path := strings.concatenate({"/usr/share/pixmaps/", icon_name, ".png"})
    if os.exists(pixmaps_path) {
        return pixmaps_path
    }
    delete(pixmaps_path)

    return ""
}

// Create a simple placeholder icon procedurally
create_placeholder_icon :: proc() -> rl.Texture2D {
    size :: ICON_SIZE

    // Create gray background
    img := rl.GenImageColor(size, size, {60, 60, 70, 255})

    // Draw a simple window-like shape
    rl.ImageDrawRectangle(&img, 4, 4, size - 8, 3, {100, 100, 120, 255})  // Title bar
    rl.ImageDrawRectangle(&img, 4, 8, size - 8, size - 12, {80, 80, 95, 255})  // Window body

    tex := rl.LoadTextureFromImage(img)
    rl.UnloadImage(img)

    return tex
}

// Load icon for an app entry (lazy loading)
load_app_icon :: proc(app: ^App_Entry, config: ^Icon_Config, placeholder: rl.Texture2D) {
    if app.icon_loaded do return
    app.icon_loaded = true

    if len(app.icon_name) == 0 {
        app.texture = placeholder
        return
    }

    // Resolve path if not already done
    if len(app.icon_path) == 0 {
        app.icon_path = resolve_icon_path(app.icon_name, config)
    }

    if len(app.icon_path) == 0 {
        app.texture = placeholder
        return
    }

    // Load texture via Raylib
    cpath := strings.clone_to_cstring(app.icon_path)
    defer delete(cpath)

    tex := rl.LoadTexture(cpath)
    if tex.id == 0 {
        app.texture = placeholder
        return
    }

    app.texture = tex
}
