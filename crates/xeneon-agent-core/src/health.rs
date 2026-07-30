use std::{
    fs,
    path::{Path, PathBuf},
    time::Instant,
};

use crate::model::{HealthSnapshot, Metric};

#[derive(Debug)]
pub struct HealthCollector {
    proc_root: PathBuf,
    sys_root: PathBuf,
    previous_cpu: Option<CpuTotals>,
    previous_network: Option<(NetworkTotals, Instant)>,
}

#[derive(Debug, Clone, Copy)]
struct CpuTotals {
    total: u64,
    idle: u64,
}

#[derive(Debug, Clone, Copy, Default)]
struct NetworkTotals {
    down: u64,
    up: u64,
}

impl Default for HealthCollector {
    fn default() -> Self {
        Self::new("/proc", "/sys")
    }
}

impl HealthCollector {
    pub fn new(proc_root: impl Into<PathBuf>, sys_root: impl Into<PathBuf>) -> Self {
        Self {
            proc_root: proc_root.into(),
            sys_root: sys_root.into(),
            previous_cpu: None,
            previous_network: None,
        }
    }

    pub fn sample(&mut self) -> HealthSnapshot {
        let now = Instant::now();
        let cpu = self.sample_cpu();
        let (network_down, network_up) = self.sample_network(now);

        HealthSnapshot {
            cpu,
            cpu_temperature: first_temperature(&self.sys_root.join("class/thermal")).map_or_else(
                || Metric::unavailable("°C"),
                |value| Metric::available(value, "°C"),
            ),
            gpu: first_number_matching(&self.sys_root.join("class/drm"), "gpu_busy_percent", 1.0)
                .map_or_else(
                    || Metric::unavailable("%"),
                    |value| Metric::available(value, "%"),
                ),
            gpu_temperature: gpu_temperature(&self.sys_root).map_or_else(
                || Metric::unavailable("°C"),
                |value| Metric::available(value, "°C"),
            ),
            memory: memory_percent(&self.proc_root.join("meminfo")).map_or_else(
                || Metric::unavailable("%"),
                |value| Metric::available(value, "%"),
            ),
            network_down,
            network_up,
            battery: battery_percent(&self.sys_root.join("class/power_supply")).map_or_else(
                || Metric::unavailable("%"),
                |value| Metric::available(value, "%"),
            ),
        }
    }

    fn sample_cpu(&mut self) -> Metric {
        let current = read_cpu_totals(&self.proc_root.join("stat"));
        let metric = current
            .zip(self.previous_cpu)
            .and_then(|(current, previous)| {
                let total = current.total.checked_sub(previous.total)?;
                let idle = current.idle.checked_sub(previous.idle)?;
                (total > 0).then(|| 100.0 * (total.saturating_sub(idle)) as f64 / total as f64)
            })
            .map_or_else(
                || Metric::unavailable("%"),
                |value| Metric::available(value, "%"),
            );
        self.previous_cpu = current;
        metric
    }

    fn sample_network(&mut self, now: Instant) -> (Metric, Metric) {
        let current = read_network_totals(&self.proc_root.join("net/dev"));
        let metrics = current
            .zip(self.previous_network)
            .and_then(|(current, (previous, previous_at))| {
                let elapsed = now.duration_since(previous_at).as_secs_f64();
                (elapsed > 0.0).then(|| {
                    (
                        Metric::available(
                            current.down.saturating_sub(previous.down) as f64 / elapsed,
                            "B/s",
                        ),
                        Metric::available(
                            current.up.saturating_sub(previous.up) as f64 / elapsed,
                            "B/s",
                        ),
                    )
                })
            })
            .unwrap_or_else(|| (Metric::unavailable("B/s"), Metric::unavailable("B/s")));
        if let Some(current) = current {
            self.previous_network = Some((current, now));
        }
        metrics
    }
}

fn read_cpu_totals(path: &Path) -> Option<CpuTotals> {
    let contents = fs::read_to_string(path).ok()?;
    let values: Vec<u64> = contents
        .lines()
        .next()?
        .strip_prefix("cpu ")?
        .split_whitespace()
        .filter_map(|value| value.parse().ok())
        .collect();
    if values.len() < 4 {
        return None;
    }
    Some(CpuTotals {
        total: values.iter().sum(),
        idle: values[3] + values.get(4).copied().unwrap_or_default(),
    })
}

fn memory_percent(path: &Path) -> Option<f64> {
    let contents = fs::read_to_string(path).ok()?;
    let mut total = None;
    let mut available = None;
    for line in contents.lines() {
        let mut fields = line.split_whitespace();
        match fields.next()? {
            "MemTotal:" => total = fields.next()?.parse::<f64>().ok(),
            "MemAvailable:" => available = fields.next()?.parse::<f64>().ok(),
            _ => {}
        }
    }
    let total = total?;
    let available = available?;
    (total > 0.0).then(|| 100.0 * (total - available) / total)
}

fn read_network_totals(path: &Path) -> Option<NetworkTotals> {
    let contents = fs::read_to_string(path).ok()?;
    let mut totals = NetworkTotals::default();
    let mut interfaces = 0;
    for line in contents.lines().skip(2) {
        let (name, values) = line.split_once(':')?;
        if name.trim() == "lo" {
            continue;
        }
        let fields: Vec<_> = values.split_whitespace().collect();
        if fields.len() < 9 {
            continue;
        }
        totals.down = totals.down.saturating_add(fields[0].parse().ok()?);
        totals.up = totals.up.saturating_add(fields[8].parse().ok()?);
        interfaces += 1;
    }
    (interfaces > 0).then_some(totals)
}

fn battery_percent(root: &Path) -> Option<f64> {
    sorted_dirs(root)
        .into_iter()
        .filter(|path| {
            fs::read_to_string(path.join("type")).is_ok_and(|value| value.trim() == "Battery")
        })
        .find_map(|path| read_number(&path.join("capacity"), 1.0))
}

fn first_temperature(root: &Path) -> Option<f64> {
    sorted_dirs(root)
        .into_iter()
        .filter_map(|path| read_number(&path.join("temp"), 1_000.0))
        .filter(|value| (-20.0..=150.0).contains(value))
        .max_by(f64::total_cmp)
}

fn gpu_temperature(sys_root: &Path) -> Option<f64> {
    first_number_matching(&sys_root.join("class/drm"), "temp1_input", 1_000.0)
}

fn first_number_matching(root: &Path, file_name: &str, divisor: f64) -> Option<f64> {
    let mut stack = vec![root.to_path_buf()];
    let mut visited = 0;
    while let Some(path) = stack.pop() {
        if visited >= 512 {
            break;
        }
        visited += 1;
        let entries = fs::read_dir(&path).ok()?;
        for entry in entries.flatten() {
            let child = entry.path();
            if child.file_name().is_some_and(|name| name == file_name)
                && let Some(value) = read_number(&child, divisor)
            {
                return Some(value);
            }
            if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                stack.push(child);
            }
        }
    }
    None
}

fn read_number(path: &Path, divisor: f64) -> Option<f64> {
    fs::read_to_string(path)
        .ok()?
        .trim()
        .parse::<f64>()
        .ok()
        .map(|value| value / divisor)
}

fn sorted_dirs(root: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<_> = fs::read_dir(root)
        .into_iter()
        .flat_map(|entries| entries.flatten())
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect();
    paths.sort();
    paths
}

#[cfg(test)]
mod tests {
    use std::{fs, thread, time::Duration};

    use super::*;

    fn write(path: &Path, contents: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }

    #[test]
    fn unavailable_is_distinct_from_zero() {
        let root = tempfile::tempdir().unwrap();
        let mut collector = HealthCollector::new(root.path().join("proc"), root.path().join("sys"));
        let health = collector.sample();
        assert!(!health.cpu.available);
        assert_eq!(health.cpu.value, None);
        assert!(!health.battery.available);
    }

    #[test]
    fn samples_proc_and_sys_metrics() {
        let root = tempfile::tempdir().unwrap();
        let proc_root = root.path().join("proc");
        let sys_root = root.path().join("sys");
        write(&proc_root.join("stat"), "cpu  100 0 50 850 0 0 0 0\n");
        write(
            &proc_root.join("meminfo"),
            "MemTotal: 1000 kB\nMemAvailable: 600 kB\n",
        );
        write(
            &proc_root.join("net/dev"),
            "Inter-| Receive | Transmit\n face |\neth0: 1000 0 0 0 0 0 0 0 500 0 0 0 0 0 0 0\n",
        );
        write(&sys_root.join("class/power_supply/BAT0/type"), "Battery\n");
        write(&sys_root.join("class/power_supply/BAT0/capacity"), "82\n");
        write(
            &sys_root.join("class/thermal/thermal_zone0/temp"),
            "45000\n",
        );

        let mut collector = HealthCollector::new(&proc_root, &sys_root);
        let first = collector.sample();
        assert_eq!(first.memory.value, Some(40.0));
        assert_eq!(first.battery.value, Some(82.0));
        assert_eq!(first.cpu_temperature.value, Some(45.0));
        assert!(!first.cpu.available);

        write(&proc_root.join("stat"), "cpu  150 0 50 900 0 0 0 0\n");
        write(
            &proc_root.join("net/dev"),
            "Inter-| Receive | Transmit\n face |\neth0: 2000 0 0 0 0 0 0 0 1500 0 0 0 0 0 0 0\n",
        );
        thread::sleep(Duration::from_millis(2));
        let second = collector.sample();
        assert!(second.cpu.available);
        assert!(second.network_down.available);
        assert!(second.network_up.available);
    }
}
