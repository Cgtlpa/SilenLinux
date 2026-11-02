package config

import (
	"context"
	"fmt"
	"math"
	"time"

	lua "github.com/yuin/gopher-lua"
)

const (
	maxLuaDepth  = 12
	maxLuaNodes  = 20000
	maxLuaString = 1024 * 1024
)

type luaParser struct {
	nodes int
}

func parseLua(data []byte) (map[string]any, error) {
	L := lua.NewState(lua.Options{SkipOpenLibs: true})
	defer L.Close()

	for _, lib := range []struct {
		name string
		fn   lua.LGFunction
	}{
		{lua.BaseLibName, lua.OpenBase},
		{lua.TabLibName, lua.OpenTable},
		{lua.StringLibName, lua.OpenString},
		{lua.MathLibName, lua.OpenMath},
	} {
		if err := L.CallByParam(lua.P{
			Fn:      L.NewFunction(lib.fn),
			NRet:    0,
			Protect: true,
		}, lua.LString(lib.name)); err != nil {
			return nil, fmt.Errorf("lua sandbox: %w", err)
		}
	}

	for _, name := range []string{"dofile", "loadfile", "load", "require", "collectgarbage", "print", "warn", "module"} {
		L.SetGlobal(name, lua.LNil)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	L.SetContext(ctx)

	fn, err := L.LoadString(string(data))
	if err != nil {
		return nil, fmt.Errorf("lua syntax: %w", err)
	}
	L.Push(fn)
	if err := L.PCall(0, 1, nil); err != nil {
		return nil, fmt.Errorf("lua execution: %w", err)
	}

	ret := L.Get(-1)
	L.Pop(1)
	if ret == lua.LNil {
		return nil, fmt.Errorf("config must return a table")
	}
	table, ok := ret.(*lua.LTable)
	if !ok {
		return nil, fmt.Errorf("config must return a table, got %s", ret.Type().String())
	}

	p := &luaParser{}
	value, err := p.convert(table, 0)
	if err != nil {
		return nil, err
	}
	out, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("config must return a table")
	}
	return out, nil
}

func (p *luaParser) convert(value lua.LValue, depth int) (any, error) {
	if depth > maxLuaDepth {
		return nil, fmt.Errorf("config is nested too deeply")
	}
	p.nodes++
	if p.nodes > maxLuaNodes {
		return nil, fmt.Errorf("config is too large")
	}
	switch v := value.(type) {
	case *lua.LNilType:
		return nil, nil
	case lua.LBool:
		return bool(v), nil
	case lua.LString:
		if len(v) > maxLuaString {
			return nil, fmt.Errorf("string value is too large")
		}
		return string(v), nil
	case lua.LNumber:
		f := float64(v)
		if math.IsNaN(f) || math.IsInf(f, 0) || math.Trunc(f) != f || f < math.MinInt64 || f > math.MaxInt64 {
			return nil, fmt.Errorf("only integer numbers are allowed")
		}
		return int64(f), nil
	case *lua.LTable:
		isArray := true
		count := 0
		v.ForEach(func(k, _ lua.LValue) {
			count++
			if _, ok := k.(lua.LNumber); !ok {
				isArray = false
			}
		})
		if isArray && count > 0 {
			first, _ := v.RawGetInt(1).(lua.LNumber)
			if int(first) != 1 {
				isArray = false
			}
		}
		if isArray {
			out := make([]any, 0, count)
			for i := 1; i <= count; i++ {
				item, err := p.convert(v.RawGetInt(i), depth+1)
				if err != nil {
					return nil, err
				}
				out = append(out, item)
			}
			return out, nil
		}
		out := make(map[string]any, count)
		var convErr error
		v.ForEach(func(k, val lua.LValue) {
			if convErr != nil {
				return
			}
			key, ok := k.(lua.LString)
			if !ok {
				convErr = fmt.Errorf("table keys must be strings")
				return
			}
			if len(key) > 256 {
				convErr = fmt.Errorf("table key is too long")
				return
			}
			item, err := p.convert(val, depth+1)
			if err != nil {
				convErr = err
				return
			}
			out[string(key)] = item
		})
		if convErr != nil {
			return nil, convErr
		}
		return out, nil
	default:
		return nil, fmt.Errorf("unsupported lua value %s", value.Type().String())
	}
}
