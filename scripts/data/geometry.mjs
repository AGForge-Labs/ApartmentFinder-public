// Geometry checks shared by the pack builder and validator. Coordinates are WGS84 longitude, latitude.
export function inRing(point,ring){let inside=false;for(let i=0,j=ring.length-1;i<ring.length;j=i++){const a=ring[i],b=ring[j];if((a[1]>point[1])!==(b[1]>point[1])&&point[0]<(b[0]-a[0])*(point[1]-a[1])/(b[1]-a[1])+a[0])inside=!inside;}return inside;}
export function inGeometry(point,geometry){const polygons=geometry.type==='Polygon'?[geometry.coordinates]:geometry.type==='MultiPolygon'?geometry.coordinates:[];return polygons.some(rings=>inRing(point,rings[0])&&!rings.slice(1).some(hole=>inRing(point,hole)));}
export function coordinateValid(p){return Array.isArray(p)&&p.length===2&&p.every(Number.isFinite)&&p[0]>=-180&&p[0]<=180&&p[1]>=-90&&p[1]<=90;}
// A conservative polygon intersection: boundary contact counts as a scope conflict.
// Uses WGS84 planar segments within this small local extent, including holes and multipolygons.
const polygonParts=g=>g.type==='Polygon'?[g.coordinates]:g.type==='MultiPolygon'?g.coordinates:[];
const ringSegments=r=>r.map((p,i)=>[p,r[(i+1)%r.length]]);
function onSegment(p,a,b){const cross=(b[0]-a[0])*(p[1]-a[1])-(b[1]-a[1])*(p[0]-a[0]);return Math.abs(cross)<1e-12&&p[0]>=Math.min(a[0],b[0])-1e-12&&p[0]<=Math.max(a[0],b[0])+1e-12&&p[1]>=Math.min(a[1],b[1])-1e-12&&p[1]<=Math.max(a[1],b[1])+1e-12;}
function segmentsIntersect(a,b,c,d){const orient=(p,q,r)=>(q[0]-p[0])*(r[1]-p[1])-(q[1]-p[1])*(r[0]-p[0]);const x=orient(a,b,c),y=orient(a,b,d),z=orient(c,d,a),w=orient(c,d,b);return ((x>0&&y<0)||(x<0&&y>0))&&((z>0&&w<0)||(z<0&&w>0))||onSegment(c,a,b)||onSegment(d,a,b)||onSegment(a,c,d)||onSegment(b,c,d);}
export function geometriesIntersect(a,b){
 for(const pa of polygonParts(a))for(const pb of polygonParts(b)){
  const ga={type:'Polygon',coordinates:pa},gb={type:'Polygon',coordinates:pb};
  if(pa[0].some(p=>inGeometry(p,gb))||pb[0].some(p=>inGeometry(p,ga)))return true;
  for(const ra of pa)for(const rb of pb)for(const [p,q] of ringSegments(ra))for(const [r,s] of ringSegments(rb))if(segmentsIntersect(p,q,r,s))return true;
 }
 return false;
}
export function boundsCenter(points){return[(Math.min(...points.map(p=>p[0]))+Math.max(...points.map(p=>p[0])))/2,(Math.min(...points.map(p=>p[1]))+Math.max(...points.map(p=>p[1])))/2];}
export function geometryPoints(g){return g.type==='Polygon'?g.coordinates.flat():g.coordinates.flat(2);}
