#version 3.7;
global_settings { assumed_gamma 1.0 }
camera { orthographic location <512,512,-1000> look_at <512,512,0> right x*1024 up y*1024 }
background { color rgbt <0,0,0,1> }
light_source { <200,900,-400> color rgb <1.2,0.8,0.35> }
light_source { <700,250,-400> color rgb <0.4,0.08,0.015> }
#include "chart.inc"
ChartSweep(1, <0,0,0>, 0.05, 0.65)
