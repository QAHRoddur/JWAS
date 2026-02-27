#!/usr/bin/env julia

"""
Generate Colab-ready notebooks from JWAS.jl wiki pages, preserving Julia code cells.

Usage:
    julia generate_jwas_colab_notebooks.jl
    julia generate_jwas_colab_notebooks.jl --output colab_notebooks
"""

module GenerateJWASColabNotebooks

using Dates
using UUIDs

try
    using JSON
catch
    import Pkg
    Pkg.add("JSON")
    using JSON
end

const WIKI_REPO_URL = "https://github.com/reworkhow/JWAS.jl.wiki.git"
const CACHE_DIR_NAME = ".jwas_wiki_cache"
const DEFAULT_OUTPUT_DIR = "."
const GITHUB_USERNAME = "QAHRoddur"
const GITHUB_REPO = "JWAS"
const CATEGORY_FOLDERS = Dict(
    "Examples" => "Examples",
    "FAQ" => "FAQ",
    "Developer" => "Developer",
)
const DATA_DIR_NAME = "data"
const PAGE_CATEGORY_OVERRIDES = Dict(
    # Force this page into Developer regardless of sidebar position.
    "create_binary_code_file" => "Developer",
)
const CUSTOM_DATA_FILES = (
    "my_GRM.csv",
    "genotypes_group1.csv",
    "genotypes_group2.csv",
    "genotypes_group3.csv",
)

function run_cmd(cmd::Cmd)
    run(cmd)
end

function clone_or_update_wiki(base_dir::String)
    cache_dir = joinpath(base_dir, CACHE_DIR_NAME)
    if !isdir(cache_dir)
        run_cmd(`git clone $WIKI_REPO_URL $cache_dir`)
        return cache_dir
    end

    if isdir(joinpath(cache_dir, ".git"))
        run_cmd(`git -C $cache_dir pull`)
    end
    return cache_dir
end

function slugify(name::String)
    s = replace(name, ".md" => "")
    s = lowercase(strip(s))
    s = replace(s, r"[^a-z0-9]+" => "_")
    s = replace(s, r"_+" => "_")
    s = strip(s, '_')
    return isempty(s) ? "untitled" : s
end

function parse_sidebar_categories(wiki_dir::String)
    sidebar_path = joinpath(wiki_dir, "_Sidebar.md")
    if !isfile(sidebar_path)
        return Dict{String, String}()
    end

    section = ""
    category_by_slug = Dict{String, String}()
    for line in split(read(sidebar_path, String), '\n')
        stripped = strip(line)
        if startswith(stripped, "# ")
            section = strip(replace(stripped, "# " => ""))
            continue
        end

        m = match(r"\[[^\]]+\]\(([^)]+)\)", stripped)
        if m === nothing
            continue
        end

        target = strip(m.captures[1])
        target = replace(target, "`" => "")
        key = slugify(target)
        isempty(key) && continue

        if haskey(CATEGORY_FOLDERS, section)
            category_by_slug[key] = CATEGORY_FOLDERS[section]
        end
    end

    return category_by_slug
end

"""
Return a vector of tuples: (segment_type, language, content)
- segment_type: "markdown" or "code"
"""
function parse_markdown_fences(text::String)
    segments = Vector{Tuple{String, String, String}}()
    lines = split(text, '\n'; keepempty=true)

    in_code = false
    code_lang = ""
    md_buf = String[]
    code_buf = String[]

    for line in lines
        if !in_code
            m = match(r"^```([A-Za-z0-9_+\-]*)\s*$", line)
            if m !== nothing
                if !isempty(md_buf)
                    push!(segments, ("markdown", "", join(md_buf, "\n")))
                    empty!(md_buf)
                end
                in_code = true
                code_lang = lowercase(strip(m.captures[1]))
                empty!(code_buf)
            else
                push!(md_buf, line)
            end
        else
            if line == "```"
                push!(segments, ("code", code_lang, join(code_buf, "\n")))
                in_code = false
                code_lang = ""
                empty!(code_buf)
            else
                push!(code_buf, line)
            end
        end
    end

    if in_code && !isempty(code_buf)
        push!(md_buf, "```" * code_lang)
        append!(md_buf, code_buf)
    end

    if !isempty(md_buf)
        push!(segments, ("markdown", "", join(md_buf, "\n")))
    end

    return segments
end

function new_cell_id()
    # Colab handles short stable ids well; strip dashes for compactness.
    return replace(string(uuid4()), "-" => "")[1:12]
end

function source_lines(source::String)
    lines = split(source, '\n'; keepempty=true)
    out = String[]
    for i in eachindex(lines)
        if i < length(lines)
            push!(out, lines[i] * "\n")
        elseif !isempty(lines[i])
            push!(out, lines[i])
        end
    end
    return out
end

function markdown_cell(source::String)
    return Dict(
        "id" => new_cell_id(),
        "cell_type" => "markdown",
        "metadata" => Dict{String, Any}(),
        "source" => source_lines(source),
    )
end

function code_cell(source::String)
    return Dict(
        "id" => new_cell_id(),
        "cell_type" => "code",
        "execution_count" => nothing,
        "metadata" => Dict{String, Any}(),
        "outputs" => Any[],
        "source" => source_lines(source),
    )
end

function colab_examples_setup_cell()
    setup = """
    # One-time setup each Colab session
    if !isdir("/content/JWAS")
        run(`git clone https://github.com/QAHRoddur/JWAS.git /content/JWAS`)
    end
    cd("/content/JWAS/Examples")
    pwd()  # should show /content/JWAS/Examples
    """
    return code_cell(strip(setup) * "\n")
end

function rewrite_custom_input_paths(code::AbstractString)
    rewritten = String(code)

    # Rewrite wiki demo_7animals lookups to local project data paths.
    rewritten = replace(
        rewritten,
        r"dataset\(\"phenotypes\.txt\",\s*dataset_name=\"demo_7animals\"\)" => "\"../$(DATA_DIR_NAME)/phenotypes.txt\"",
    )
    rewritten = replace(
        rewritten,
        r"dataset\(\"pedigree\.txt\",\s*dataset_name=\"demo_7animals\"\)" => "\"../$(DATA_DIR_NAME)/pedigree.txt\"",
    )
    rewritten = replace(
        rewritten,
        r"dataset\(\"genotypes\.txt\",\s*dataset_name=\"demo_7animals\"\)" => "\"../$(DATA_DIR_NAME)/genotypes.txt\"",
    )
    rewritten = replace(
        rewritten,
        r"dataset\(\"map\.txt\",\s*dataset_name=\"demo_7animals\"\)" => "\"../$(DATA_DIR_NAME)/map.txt\"",
    )

    for name in CUSTOM_DATA_FILES
        rewritten = replace(rewritten, "\"$name\"" => "\"../$(DATA_DIR_NAME)/$name\"")
        rewritten = replace(rewritten, "'$name'" => "'../$(DATA_DIR_NAME)/$name'")
    end
    return rewritten
end

function initial_cells(title::String, notebook_rel_path::String)
    badge = "[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)]" *
            "(https://colab.research.google.com/github/$(GITHUB_USERNAME)/$(GITHUB_REPO)/blob/main/" *
            notebook_rel_path * ")\n"

    intro = "# " * title * "\n\n" * badge *
            "\nThis notebook is auto-generated from the JWAS.jl wiki page.\n"

    # Keep setup in Julia as requested.
    setup = """
    using Pkg
    Pkg.add("JWAS")
    Pkg.precompile()
    using JWAS
    """

    return [
        markdown_cell(intro),
        code_cell(strip(setup) * "\n"),
    ]
end

function build_notebook_from_markdown(
    md_text::String,
    title::String,
    rel_path::String;
    add_examples_setup::Bool=false,
)
    cells = initial_cells(title, rel_path)
    if add_examples_setup
        push!(cells, colab_examples_setup_cell())
    end
    segments = parse_markdown_fences(md_text)

    for (seg_type, lang, content) in segments
        cleaned = strip(content, ['\n', '\r'])
        isempty(strip(cleaned)) && continue

        if seg_type == "markdown"
            push!(cells, markdown_cell(cleaned * "\n"))
        elseif lang in ("julia", "jl", "")
            adjusted = rewrite_custom_input_paths(cleaned)
            push!(cells, code_cell(adjusted * "\n"))
        else
            note = "# Original fenced language: " * (isempty(lang) ? "plain" : lang) * "\n" *
                   cleaned * "\n"
            push!(cells, code_cell(note))
        end
    end

    return Dict(
        "cells" => cells,
        "metadata" => Dict(
            "colab" => Dict(
                "name" => title * ".ipynb",
                "provenance" => Any[],
            ),
            "kernelspec" => Dict(
                "display_name" => "Julia 1.11",
                "language" => "julia",
                "name" => "julia-1.11",
            ),
            "language_info" => Dict(
                "name" => "julia",
                "file_extension" => ".jl",
            ),
        ),
        "nbformat" => 4,
        "nbformat_minor" => 5,
    )
end

function convert_all_pages(wiki_dir::String, output_dir::String, repo_output_prefix::String)
    mkpath(output_dir)
    for folder in values(CATEGORY_FOLDERS)
        mkpath(joinpath(output_dir, folder))
    end
    mkpath(joinpath(output_dir, DATA_DIR_NAME))

    converted = Vector{Tuple{String, String, String}}()
    category_by_slug = parse_sidebar_categories(wiki_dir)

    md_files = filter(f -> endswith(f, ".md"), readdir(wiki_dir; join=true))
    sort!(md_files)

    for md_file in md_files
        page_stem = splitext(basename(md_file))[1]
        if page_stem in ("Home", "_Sidebar")
            continue
        end

        page_title = replace(page_stem, "-" => " ")
        notebook_name = slugify(page_stem) * ".ipynb"
        page_key = slugify(page_stem)
        category_folder = get(category_by_slug, page_key, "Examples")
        category_folder = get(PAGE_CATEGORY_OVERRIDES, page_key, category_folder)

        notebook_path = joinpath(output_dir, category_folder, notebook_name)
        rel_path = isempty(repo_output_prefix) ? joinpath(category_folder, notebook_name) :
                  joinpath(repo_output_prefix, category_folder, notebook_name)
        rel_path = replace(rel_path, "\\" => "/")

        md_text = read(md_file, String)
        notebook_data = build_notebook_from_markdown(
            md_text,
            page_title,
            rel_path;
            add_examples_setup=(category_folder == "Examples"),
        )
        write(notebook_path, JSON.json(notebook_data, 2))
        push!(converted, (page_title, notebook_path, category_folder))
    end

    return converted
end

function write_index(output_dir::String, converted::Vector{Tuple{String, String, String}})
    index_path = joinpath(output_dir, "README.md")
    io = IOBuffer()
    write(io, "# JWAS Colab Notebooks\n\n")
    write(io, "Auto-generated notebooks from the JWAS.jl wiki (Julia cells preserved).\n\n")
    write(io, "## Notebooks\n")
    for category in ("Examples", "FAQ", "Developer")
        write(io, "\n### $(category)\n")
        for (title, path, folder) in converted
            if folder == category
                rel = replace(path, output_dir * "/" => "")
                write(io, "- `$(title)` -> `$(rel)`\n")
            end
        end
    end
    write(io, "\n## Next Step\n\n")
    write(io, "Notebook badges are configured for `QAHRoddur/JWAS`.\n")
    write(io, "Put custom input files under `$(DATA_DIR_NAME)/` (e.g., `$(DATA_DIR_NAME)/my_GRM.csv`).\n")
    write(index_path, String(take!(io)))
    return index_path
end

function parse_args(argv::Vector{String})
    output = DEFAULT_OUTPUT_DIR
    i = 1
    while i <= length(argv)
        if argv[i] == "--output" && i < length(argv)
            output = argv[i + 1]
            i += 2
        else
            i += 1
        end
    end
    return output
end

function main(argv::Vector{String})
    base_dir = pwd()
    output_arg = parse_args(argv)
    output_dir = isabspath(output_arg) ? output_arg : joinpath(base_dir, output_arg)

    repo_output_prefix = output_arg
    if isabspath(output_arg)
        repo_output_prefix = basename(output_arg)
    else
        repo_output_prefix = replace(output_arg, r"^\./" => "")
    end
    repo_output_prefix = repo_output_prefix == "." ? "" : repo_output_prefix
    repo_output_prefix = replace(repo_output_prefix, "\\" => "/")

    wiki_dir = clone_or_update_wiki(base_dir)
    converted = convert_all_pages(wiki_dir, output_dir, repo_output_prefix)
    index_path = write_index(output_dir, converted)

    println("Converted $(length(converted)) wiki pages into notebooks.")
    println("Output folder: $output_dir")
    println("Index file: $index_path")
end

end # module

GenerateJWASColabNotebooks.main(ARGS)
