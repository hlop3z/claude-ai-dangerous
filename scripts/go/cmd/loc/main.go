// Command loc reports source files by line count, so oversized files surface
// against the thresholds in .canon/guidelines.md.
//
// Replaces the former scripts/sh/loc_rust.sh, which was Rust-only and could not
// report structured output.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"

	"github.com/spf13/cobra"
)

// Directories that never hold reviewable source.
var skipDirs = []string{
	".git", "node_modules", "target", "dist", "build", "vendor",
	".venv", "__pycache__", ".docusaurus", ".next",
}

type entry struct {
	Path  string `json:"path"`
	Lines int    `json:"lines"`
}

func main() {
	var (
		min    int
		exts   []string
		asJSON bool
	)

	root := &cobra.Command{
		Use:   "loc [dir]",
		Short: "Report source files by line count",
		Long: "Walks a directory and reports files at or above a line threshold, " +
			"largest first.\n\nThresholds from .canon/guidelines.md: under 300 is good, " +
			"300-600 acceptable, over 600 needs review.",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			dir := "."
			if len(args) == 1 {
				dir = args[0]
			}
			found, err := walk(dir, min, exts)
			if err != nil {
				return err
			}
			return report(cmd.OutOrStdout(), found, asJSON)
		},
		SilenceUsage: true,
	}

	root.Flags().IntVarP(&min, "min", "m", 300, "only report files with at least this many lines")
	root.Flags().StringSliceVarP(&exts, "ext", "e", nil, "limit to these extensions (repeatable, e.g. -e go -e py)")
	root.Flags().BoolVar(&asJSON, "json", false, "emit JSON instead of a table")

	if err := root.Execute(); err != nil {
		os.Exit(1)
	}
}

func walk(dir string, min int, exts []string) ([]entry, error) {
	var found []entry

	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if slices.Contains(skipDirs, d.Name()) {
				return fs.SkipDir
			}
			return nil
		}
		if !matchesExt(path, exts) {
			return nil
		}
		n, err := countLines(path)
		if errors.Is(err, errBinary) {
			return nil
		}
		if err != nil {
			// An unreadable file is reported, not fatal — one bad file must not
			// abandon the whole walk.
			fmt.Fprintf(os.Stderr, "loc: skipping %s: %v\n", path, err)
			return nil
		}
		if n >= min {
			found = append(found, entry{Path: filepath.ToSlash(path), Lines: n})
		}
		return nil
	})
	if err != nil {
		return nil, err
	}

	sort.Slice(found, func(i, j int) bool { return found[i].Lines > found[j].Lines })
	return found, nil
}

func matchesExt(path string, exts []string) bool {
	if len(exts) == 0 {
		return true
	}
	got := strings.TrimPrefix(filepath.Ext(path), ".")
	for _, want := range exts {
		if strings.EqualFold(got, strings.TrimPrefix(want, ".")) {
			return true
		}
	}
	return false
}

// errBinary marks a file that holds no reviewable source.
var errBinary = errors.New("binary file")

func countLines(path string) (int, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	if len(b) == 0 {
		return 0, nil
	}
	// A NUL byte in the first chunk is the standard binary heuristic. Without it
	// a compiled artifact reports tens of thousands of "lines" and buries the
	// real source in the report.
	if bytes.IndexByte(b[:min(len(b), 8000)], 0) != -1 {
		return 0, errBinary
	}
	n := strings.Count(string(b), "\n")
	// A final line without a trailing newline still counts.
	if !strings.HasSuffix(string(b), "\n") {
		n++
	}
	return n, nil
}

func report(w interface{ Write([]byte) (int, error) }, found []entry, asJSON bool) error {
	if asJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		if found == nil {
			found = []entry{}
		}
		return enc.Encode(found)
	}
	if len(found) == 0 {
		fmt.Fprintln(w, "no files at or above the threshold")
		return nil
	}
	for _, e := range found {
		flag := ""
		if e.Lines > 600 {
			flag = "  <- review required"
		}
		fmt.Fprintf(w, "%6d  %s%s\n", e.Lines, e.Path, flag)
	}
	return nil
}
