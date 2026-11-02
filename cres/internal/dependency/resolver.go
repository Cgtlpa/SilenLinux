package dependency

import (
	"fmt"
	"sort"
	"strings"

	"silen/cres/internal/model"
)

type Options struct {
	NoDeps    bool
	Reinstall bool
	Force     bool
}

type Resolver struct {
	Index     model.Index
	Installed map[string]model.Installed
}

func New(index model.Index, installed map[string]model.Installed) *Resolver {
	return &Resolver{Index: index, Installed: installed}
}

func (r *Resolver) Resolve(requested []string, opt Options) (model.Plan, error) {
	plan := model.Plan{Reasons: map[string]string{}, Upgrade: map[string]string{}}
	byName := map[string]*model.Package{}
	for i := range r.Index.Packages {
		pkg := &r.Index.Packages[i]
		byName[pkg.Name] = pkg
	}
	provider := func(name string) *model.Package {
		if pkg := byName[name]; pkg != nil {
			return pkg
		}
		for i := range r.Index.Packages {
			for _, provided := range r.Index.Packages[i].Provides {
				if provided == name {
					return &r.Index.Packages[i]
				}
			}
		}
		return nil
	}

	state := map[string]int{}
	var order []string
	var stack []string
	var resolve func(name, op, ver, reason string, explicit bool) error
	resolve = func(name, op, ver, reason string, explicit bool) error {
		pkg := provider(name)
		if pkg == nil {
			if inst, ok := r.Installed[name]; ok {
				if model.Satisfies(inst.Version, op, ver) {
					return nil
				}
				return fmt.Errorf("installed %s %s does not satisfy %s%s", name, inst.Version, op, ver)
			}
			return fmt.Errorf("no package provides %q", name)
		}
		if op != "" && !model.Satisfies(pkg.Version, op, ver) {
			return fmt.Errorf("%s %s does not satisfy %s%s", pkg.Name, pkg.Version, op, ver)
		}
		key := pkg.Name
		if state[key] == 2 {
			return nil
		}
		if state[key] == 1 {
			chain := append(append([]string{}, stack...), key)
			return fmt.Errorf("dependency cycle: %s", strings.Join(chain, " -> "))
		}
		state[key] = 1
		stack = append(stack, key)
		defer func() {
			stack = stack[:len(stack)-1]
			state[key] = 2
		}()

		for _, dep := range pkg.Deps {
			depName, depOp, depVer, err := model.ParseConstraint(dep)
			if err != nil {
				return fmt.Errorf("%s: %w", pkg.Name, err)
			}
			if opt.NoDeps {
				continue
			}
			if err := resolve(depName, depOp, depVer, pkg.Name, false); err != nil {
				return err
			}
		}

		for _, conflict := range pkg.Conflicts {
			if conflict == key {
				continue
			}
			if _, ok := r.Installed[conflict]; ok && !opt.Force {
				return fmt.Errorf("%s conflicts with installed package %s", pkg.Name, conflict)
			}
			if _, ok := plan.Reasons[conflict]; ok && !opt.Force {
				return fmt.Errorf("%s conflicts with %s", pkg.Name, conflict)
			}
		}

		for _, replaced := range pkg.Replaces {
			if replaced == key {
				continue
			}
			if _, ok := r.Installed[replaced]; ok {
				plan.Remove = append(plan.Remove, replaced)
			}
		}

		installed, isInstalled := r.Installed[key]
		if isInstalled && !opt.Reinstall {
			if !explicit && model.Satisfies(installed.Version, op, ver) {
				return nil
			}
			if model.CompareVersions(installed.Version, pkg.Version) >= 0 {
				return nil
			}
		}
		if isInstalled {
			plan.Upgrade[key] = installed.Version
		}
		if reason == "" {
			reason = "requested"
		}
		plan.Reasons[key] = reason
		order = append(order, key)
		return nil
	}

	seen := map[string]bool{}
	for _, name := range requested {
		name = strings.TrimSpace(name)
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		if err := resolve(name, "", "", "", true); err != nil {
			return plan, err
		}
	}

	plan.Remove = dedupe(plan.Remove)
	plan.Install = nil
	for _, name := range order {
		pkg := byName[name]
		if pkg == nil {
			continue
		}
		if inst, ok := r.Installed[name]; ok && !opt.Reinstall && model.CompareVersions(inst.Version, pkg.Version) >= 0 {
			continue
		}
		plan.Install = append(plan.Install, *pkg)
	}
	if len(plan.Install) == 0 {
		plan.Reasons = map[string]string{}
	}
	return plan, nil
}

func dedupe(list []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, item := range list {
		if item == "" || seen[item] {
			continue
		}
		seen[item] = true
		out = append(out, item)
	}
	return out
}

func (r *Resolver) Dependents(name string) []string {
	var out []string
	for pkgName, inst := range r.Installed {
		if pkgName == name {
			continue
		}
		for _, dep := range inst.Deps {
			depName, _, _, err := model.ParseConstraint(dep)
			if err == nil && depName == name {
				out = append(out, pkgName)
				break
			}
		}
	}
	sort.Strings(out)
	return out
}

func (r *Resolver) Orphans() []string {
	var out []string
	for name, inst := range r.Installed {
		if inst.Explicit {
			continue
		}
		if len(r.Dependents(name)) == 0 {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}
