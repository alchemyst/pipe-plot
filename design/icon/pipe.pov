#version 3.7;
global_settings { assumed_gamma 1.0 max_trace_level 10 }

// Dimensions in arbitrary units. The open connection is at the left (-X).
#declare PipeLength = 3.4;
#declare PipeOuter = 1.36;
#declare PipeInner = 1.02;
#declare FlangeRadius = 3.07;
#declare FlangeThickness = 0.40;
#declare BoltCircle = 2.50;
#declare BoltRadius = 0.18;
#declare BoltCount = 8;
#declare FilletRadius = 0.11;
#declare EdgeRadius = FilletRadius / 5;

camera {
  // Camera is centered on the chart, to the right of the pipe.
  // Perspective makes the flange face visible while the pipe stays horizontal.
  perspective
  location <3.0, 0, -16>
  look_at <3.0, 0, 0>
  angle 70
  right x up y
}
background { color rgbt <0,0,0,1> }
// Broad studio lights create controlled, elongated highlights on the metal.
light_source { <-4, 7, -7> color rgb 1.15 area_light <5,0,0>, <0,0,3>, 7,7 adaptive 1 jitter }
light_source { <3, 3, -8> color rgb <0.75,0.80,0.87> area_light <5,0,0>, <0,3,0>, 7,7 adaptive 1 jitter }
// A warm source near the plot suggests its glow reflecting in the flange.
// This is a matched studio light, not physical illumination from the separate plot render.
light_source { <4.0, 1.6, -2.4> color rgb <0.65,0.18,0.025> area_light <0,2,0>, <0,0,2>, 7,7 adaptive 1 jitter }

// A studio card is visible to reflection rays, but not to the camera. This
// supplies the broad light/dark bands stainless steel needs while preserving
// a transparent background for compositing.
sphere {
  <0,0,0>, 100
  hollow
  pigment {
    gradient y
    color_map {
      [0.00 rgb <0.045,0.055,0.07>]
      [0.39 rgb <0.06,0.07,0.09>]
      [0.55 rgb <0.20,0.23,0.27>]
      [0.58 rgb <0.72,0.76,0.80>]
      [0.61 rgb <0.20,0.23,0.27>]
      [0.64 rgb <0.07,0.08,0.10>]
      [0.70 rgb <0.10,0.11,0.13>]
      [0.78 rgb <0.35,0.38,0.42>]
      [0.83 rgb <0.08,0.09,0.11>]
      [1.00 rgb <0.045,0.055,0.07>]
    }
    scale 200 translate <0,-100,0>
  }
  finish { ambient 1 diffuse 0 }
  no_image no_shadow
}

#declare Steel = texture {
  pigment { color rgb <0.46,0.48,0.50> }
  // Stretched noise forms fine lengthwise variation in the cylinder surface.
  normal { bumps 0.008 scale <0.018,0.55,0.55> }
  finish {
    ambient 0.035 diffuse 0.25 brilliance 1.8
    specular 0.95 roughness 0.012 metallic 0.85
    reflection { 0.42 metallic }
  }
}
// CSG keeps the inlet and bolt holes real, rather than painted on.
union {
  difference {
    cylinder { <0,0,0>, <PipeLength,0,0>, PipeOuter }
    cylinder { <-0.01,0,0>, <PipeLength+0.01,0,0>, PipeInner }
  }
  difference {
    // Straight center and rolled outer rim, tangent to both flat faces.
    union {
      cylinder { <-FlangeThickness,0,0>, <0.05,0,0>, FlangeRadius-EdgeRadius }
      cylinder { <-FlangeThickness+EdgeRadius,0,0>, <0.05-EdgeRadius,0,0>, FlangeRadius }
      torus { FlangeRadius-EdgeRadius, EdgeRadius rotate z*90 translate <-FlangeThickness+EdgeRadius,0,0> }
      torus { FlangeRadius-EdgeRadius, EdgeRadius rotate z*90 translate <0.05-EdgeRadius,0,0> }
    }
    cylinder { <-FlangeThickness-0.01,0,0>, <0.06,0,0>, PipeInner }
    #for (I, 0, BoltCount-1)
      #declare A = 2*pi*I/BoltCount;
      #declare HoleY = BoltCircle*cos(A);
      #declare HoleZ = BoltCircle*sin(A);
      cylinder { <-FlangeThickness-0.01,HoleY,HoleZ>, <0.06,HoleY,HoleZ>, BoltRadius }
      // Cut a quarter-round at each end of the through hole.
      #for (Side, 0, 1)
        #if (Side=0)
          #declare FaceX = -FlangeThickness;
          #declare CenterX = FaceX+EdgeRadius;
        #else
          #declare FaceX = 0.05;
          #declare CenterX = FaceX-EdgeRadius;
        #end
        difference {
          cylinder { <min(FaceX,CenterX)-0.001,HoleY,HoleZ>, <max(FaceX,CenterX)+0.001,HoleY,HoleZ>, BoltRadius+EdgeRadius }
          torus { BoltRadius+EdgeRadius, EdgeRadius rotate z*90 translate <CenterX,HoleY,HoleZ> }
        }
      #end
    #end
  }
  // Quarter-round fillet: tangent to the flange face and pipe surface.
  // Subtract a toroidal cutter from an annular collar to form the blend.
  difference {
    cylinder { <0.049,0,0>, <0.05+FilletRadius,0,0>, PipeOuter+FilletRadius }
    cylinder { <0.048,0,0>, <0.051+FilletRadius,0,0>, PipeOuter-0.005 }
    torus {
      PipeOuter+FilletRadius, FilletRadius
      rotate z*90
      translate <0.05+FilletRadius,0,0>
    }
  }
  texture { Steel }
}
