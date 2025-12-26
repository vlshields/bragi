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
    name:    string,
    exec:    string,
    comment: string,
}

State :: struct {
    apps:           [dynamic]App_Entry,
    filtered:       [dynamic]^App_Entry,
    input:          [dynamic]u8,
    selected:       int,
    scroll_offset:  int,
}

VISIBLE_ITEMS :: 10
ITEM_HEIGHT :: 32
WIDTH :: 600
HEIGHT :: 400

main :: proc() {
    state: State
    state.apps = find_applications()
    defer delete(state.apps)
    defer delete(state.filtered)
    defer delete(state.input)

    // Initially show all apps
    filter_apps(&state, "")

    rl.SetConfigFlags({.WINDOW_UNDECORATED})
    rl.InitWindow(WIDTH, HEIGHT, "Launcher")
    rl.SetTargetFPS(60)
    
    // Center window on screen
    monitor := rl.GetCurrentMonitor()
    mx := rl.GetMonitorWidth(monitor)
    my := rl.GetMonitorHeight(monitor)
    rl.SetWindowPosition((mx - WIDTH) / 2, (my - HEIGHT) / 2)

    for !rl.WindowShouldClose() {
        handle_input(&state)
        draw(&state)
    }

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
        
        // Highlight selected
        if i == state.selected {
            rl.DrawRectangle(10, y, WIDTH - 20, ITEM_HEIGHT - 2, {60, 60, 80, 255})
        }
        
        rl.DrawText(
            strings.clone_to_cstring(app.name),
            20, y + 6, 18, {200, 200, 210, 255},
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
