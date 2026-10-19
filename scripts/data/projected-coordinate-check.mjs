import {coordinateValid} from './geometry.mjs';

const SIGN=1n<<63n,MASK=(1n<<64n)-1n;
function orderedBits(value){
 const view=new DataView(new ArrayBuffer(8));view.setFloat64(0,value);
 const bits=view.getBigUint64(0);
 return bits&SIGN?(~bits)&MASK:bits|SIGN;
}

// Only recomputed diagram projections use this comparison. Math.log/tan/exp/
// atan are implementation-approximated; the 2026-10-12 captured difference is
// four adjacent Float64 values. Eight steps bound numerical roundoff tightly;
// this is neither geographic uncertainty nor permission to rewrite stored pins.
// Literal source coordinates, source metadata and pack-byte preservation stay
// exact. Geographic scope is independently checked by the caller.
export function reprojectedCoordinatesMatch(saved,recomputed){
 if(!coordinateValid(saved)||!coordinateValid(recomputed))return false;
 return saved.every((value,index)=>{
  if(value===recomputed[index])return true;
  const a=orderedBits(value),b=orderedBits(recomputed[index]);
  return (a>b?a-b:b-a)<=8n;
 });
}
