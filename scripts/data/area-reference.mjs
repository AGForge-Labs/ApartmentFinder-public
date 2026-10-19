// Street-only area references require independent county street observations.
export function areaReferenceSupported(reference,countyAddresses){
 const normalized=s=>s.toUpperCase().replace(/\s+/g,' ').trim();
 const streets=reference.replace(/ \(area reference\)$/,'').split('/').map(normalized);
 const supported=countyAddresses.map(a=>normalized(a.replace(/^\s*\d+\s+/,'')));
 return streets.length>0&&streets.every(s=>s.length>0&&supported.includes(s));
}
