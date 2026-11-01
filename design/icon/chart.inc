// Rising cosine chirp in the 1024px canvas, with Y pointing upwards.
// T runs from 0 to 1; quadratic phase tightens the waves to the right.
#macro ChartPoint(T)
  <390 + 528*T, 456 + 80*T + 65*cos(4*pi*T*T), 0>
#end
#declare ChartIntervals = 24;
#declare ChartRadius = 10.5;

// Shared geometry for the orthographic bloom mask and perspective pipe scene.
#macro ChartSweep(PlotScale, PlotOffset, DepthTolerance, Glow)
  sphere_sweep {
    cubic_spline
    ChartIntervals + 3,
    // First and last samples only control the endpoint tangents.
    #for (I, -1, ChartIntervals + 1)
      #local T = I/ChartIntervals;
      (PlotScale*ChartPoint(T) + PlotOffset), ChartRadius*PlotScale
      #if (I < ChartIntervals + 1) , #end
    #end
    tolerance DepthTolerance
    texture {
      pigment { color rgb <1,0.32,0.025> }
      finish { ambient Glow diffuse 0.25 specular 0.65 roughness 0.035 }
    }
  }
#end
