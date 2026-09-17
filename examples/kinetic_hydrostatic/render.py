#!/usr/bin/env python3
"""Plot saved Formurae diagnostics; no simulation calculations."""
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.ticker import NullLocator
from gallery import load_report

HERE=Path(__file__).resolve().parent


def main():
    runs=load_report()['runs']
    plt.rcParams.update({'font.size':10,'axes.spines.top':False,'axes.spines.right':False,
                         'svg.fonttype':'none','svg.hashsalt':'kinetic-hydrostatic'})
    fig,axes=plt.subplots(1,2,figsize=(10,4.2),layout='constrained')
    for chart,color,label in (('cartesian','#265b9a','Cartesian'),('mapped','#b65f2d','Mapped')):
        for balanced,style in ((0,'-'),(1,':')):
            selected=sorted((r for r in runs if r['chart']==chart and r['scenario']=='rest' and r['duration']==1 and r['balanced']==balanced),key=lambda r:r['grid'])
            axes[0].plot([r['grid'] for r in selected],[r['max_speed'] for r in selected],color=color,
                         linestyle=style,marker='o' if chart=='cartesian' else 's',markersize=5,
                         markerfacecolor='white' if balanced else color,
                         label=f"{label}: {'balanced' if balanced else 'ordinary'}")
        for size,style in ((16,':'),(32,'--'),(64,'-')):
            run=next(r for r in runs if r['chart']==chart and r['scenario']=='perturbation' and r['grid']==size and r['time_scale']==1)
            hist=run['history']
            axes[1].plot([h['time'] for h in hist],[h['densityMode']/hist[0]['densityMode'] for h in hist],
                         color=color,linestyle=style,label=f'{label}: {size} × {size}')
    axes[0].set_title('Unintended motion from resting water',loc='left')
    axes[0].set_xlabel('Physical cells per coordinate')
    axes[0].set_ylabel('Maximum speed over t = 0 to 2π')
    axes[0].set_xscale('log',base=2)
    axes[0].set_xticks([16,32,64],['16','32','64'])
    axes[0].xaxis.set_minor_locator(NullLocator())
    axes[0].ticklabel_format(axis='y',style='sci',scilimits=(0,0))
    axes[0].legend(frameon=False,fontsize=8,loc='upper right')
    axes[1].set_title('Evolution of a small density disturbance',loc='left')
    axes[1].set_xlabel('Physical time')
    axes[1].set_ylabel('Projected density amplitude / initial value')
    axes[1].axhline(0,color='#999',linewidth=.6)
    axes[1].legend(frameon=False,fontsize=8,loc='upper right')
    for ax in axes:
        ax.grid(alpha=.2)
    svg=HERE/'results/hydrostatic.svg'
    fig.savefig(svg,metadata={'Date':None})
    svg.write_text('\n'.join(line.rstrip() for line in svg.read_text().splitlines())+'\n')
    fig.savefig(HERE/'results/hydrostatic.png',dpi=180)
    plt.close(fig)


if __name__=='__main__':
    main()
