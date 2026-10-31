"""Render the checked-in data and the actual Swift PeakFinder selections."""
import csv
from pathlib import Path
import matplotlib.pyplot as plt

root = Path(__file__).resolve().parent
rows = list(csv.reader((root / 'samples.csv').open()))
titles = ['Smooth daily load cycle', 'CPU utilization with a short burst',
          'Rising temperature with disturbance and recovery',
          'Irregularly sampled pressure with a capture gap', 'Monotonic counter']
ylabels = ['Load (%)', 'CPU (%)', 'Temperature (°C)', 'Pressure (kPa)', 'Count (k)']
fig, axes = plt.subplots(5, 1, figsize=(13, 15), constrained_layout=True)
for n, ax in enumerate(axes):
    data = [r for r in rows if int(r[0]) == n]
    for segment in dict.fromkeys(r[3] for r in data):
        subset = [r for r in data if r[3] == segment]
        ax.plot([float(r[1]) for r in subset], [float(r[2]) for r in subset], color='#2878b5', lw=1.4, marker='.' if n == 3 else None, markersize=3)
    for r in data:
        if r[4]:
            x,y = float(r[1]),float(r[2])
            ax.scatter(x,y, color='#c33737', s=30, zorder=3, marker='^' if r[4]=='peak' else 'v')
            ax.annotate(f'{r[4]} {y:.3g}', (x,y), xytext=(0, 13 if r[4]=='peak' else -17), textcoords='offset points', ha='center', fontsize=9, bbox=dict(boxstyle='round,pad=.25',fc='white',ec='#bbbbbb'))
    ax.set(title=titles[n], ylabel=ylabels[n], xlabel='Time (s)', xlim=(0,600))
    ax.margins(y=.24)
    ax.grid(alpha=.2)
fig.suptitle('PipePlot peak selection — actual Swift results', fontsize=16)
fig.savefig(root / 'peak-review.png', dpi=160)
