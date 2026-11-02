package log

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Logger struct {
	mu      sync.Mutex
	writers []io.Writer
	file    *os.File
}

func New(path string, extra io.Writer) (*Logger, error) {
	l := &Logger{}
	if extra != nil {
		l.writers = append(l.writers, extra)
	}
	if path != "" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			return nil, err
		}
		l.file = f
		l.writers = append(l.writers, f)
	}
	return l, nil
}

func (l *Logger) Printf(format string, args ...any) {
	if l == nil {
		return
	}
	line := fmt.Sprintf(format, args...)
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, w := range l.writers {
		fmt.Fprintf(w, "%s %s\n", time.Now().Format("15:04:05"), line)
	}
}

func (l *Logger) Line(line string) {
	l.Printf("%s", line)
}

func (l *Logger) Write(p []byte) (int, error) {
	for _, line := range strings.Split(strings.TrimRight(string(p), "\n"), "\n") {
		if line != "" {
			l.Line(line)
		}
	}
	return len(p), nil
}

func (l *Logger) Close() {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file != nil {
		_ = l.file.Close()
		l.file = nil
	}
}
