// Explicit adjudications of every saved GILIS20 candidate, grounded in current public county evidence.
import {readFile,writeFile} from 'node:fs/promises';import {geometriesIntersect} from './geometry.mjs';
import {deriveJoinBasis,validateCountyReconciliation} from './identity-evidence.mjs';
import {validateDeliveryAreaException} from './delivery-area-exceptions.mjs';
const read=async p=>JSON.parse(await readFile(p));const old=await read('research/geography/county-gilis20.json'),polygons=await read('research/geography/county-gilis20-polygons.json'),parcels=await read('research/geography/county-parcel-identities.json'),zips=await read('research/geography/county-zips.json');
const pairs=`16327412000 spanish-ridge
16327710000 BOUNDARY:spanish-wells
16327811000 spanish-ridge
16328110000 NEW:islands-spanish-trail
16328111000 NEW:islands-spanish-trail
16328811000 southern-vista
16328812000 southern-vista
16329201017 zerzura
16329301020 st-clair
16329411000 ALIAS:michael-b
16329412004 pace
16329701025 level25-durango
16329801025 south-beach
16330101003 UNKNOWN:revel-vegas
16330519000 amber-hills
16330616002 abode-red-rock
16330801009 crescendo
16330819000 ALIAS:portola-russell
16331111000 ALIAS:southwest-ranch
16331516000 viviani
16331801022 sunset-canyon
16331813000 tesora
16332113002 ALIAS:ely-gramercy
16332201028 level25-oquendo
16332501012 melody
16332601006 evo
16332701036 solana-post
16332801019 sw
16332811000 alcove
16333110000 morgyn-ridge
16333113000 morgyn-ridge
16333511000 ALIAS:san-tropez
16333710000 cimarron-hills
16334113000 ALIAS:tango-bay
17603510000 tuscano
17604501019 2one5
17604701024 wyatt
17604710000 coronado-palms
17604712000 ALIAS:cabrillo
17605219000 apache-hills
17605414000 ALIAS:falls-rhodes-ranch
17605710000 ALIAS:esplanade
17605711000 ALIAS:esplanade
17605801013 arbor-pointe
17605810000 vistana
17605811000 vistana
17605812000 vistana
17606617000 acerno
17608501018 clubs-rhodes-ranch
17610111000 NEW:ashton-place
17610319000 NEW:la-paloma
17615513000 everett
17620511000 sunset-cliffs
17620514000 sunset-cliffs
17622201027 OUT:gallery`.split('\n').map(l=>l.split(' '));
const assignments=new Map(pairs);const mapped=await read('research/maps/public-map-facts.json');const records=[];
const tsv=(await readFile('research/communities.tsv','utf8')).trimEnd().split(/\r?\n/),headers=tsv.shift().replace(/^\uFEFF/,'').split('\t');
const identities=tsv.map(l=>Object.fromEntries(l.split('\t').map((v,i)=>[headers[i],v])));
const joinRaw={identities,maps:mapped,zips,countyParcels:parcels,countyPolygons:polygons,audits:await read('research/audits/site-audit.json'),cadastralObservations:await read('research/geography/cadastral-identity-observations.json'),areaException:await read('research/geography/delivery-area-exceptions/spanish-wells.json')};
const exceptionErrors=validateDeliveryAreaException(joinRaw.areaException,joinRaw);if(exceptionErrors.length)throw Error(exceptionErrors.join('\n'));
for(const f of old.data.features){const apn=f.attributes.APN,p=parcels.find(p=>p.candidateAPN===apn),lookup=p.lookups.at(-1),poly=polygons.data.features.find(p=>p.properties.APN===apn);const points=poly.geometry.type==='Polygon'?poly.geometry.coordinates.flat():poly.geometry.coordinates.flat(2);const ref=[(Math.min(...points.map(p=>p[0]))+Math.max(...points.map(p=>p[0])))/2,(Math.min(...points.map(p=>p[1]))+Math.max(...points.map(p=>p[1])))/2];const scopeCountyZIPs=zips.data.features.filter(z=>geometriesIntersect(poly.geometry,z.geometry)).map(z=>String(z.properties.ZIP));
 let a=assignments.get(apn),category='matchedExisting',communityID=a,candidateName='',notes=[];
 if(!a){if(!lookup.landUse||!/^40\.|^41\.|^51\.|^92\./.test(lookup.landUse))throw Error('Unadjudicated record '+apn);category='excludedNonResidential';communityID=null;notes.push('Current assessor use is outside apartment/condo/townhome scope. GILIS20 AOCAP is not a residential-only count.');}
 else if(a.startsWith('ALIAS:')){category='matchedLegalAlias';communityID=a.slice(6);notes.push('Current county legal subdivision label differs from community branding; same address or directly overlapping official unit map. Not a separate community.');}
 else if(a.startsWith('NEW:')){category='addedCommunity';communityID=a.slice(4);notes.push('Newly identified residential group, verified by current county subdivision/land-use evidence and in-scope county ZIP geometry. No building/unit coordinates inferred.');}
 else if(a.startsWith('BOUNDARY:')){category='addedDeliveryAreaException';communityID=a.slice(9);notes.push('Official postal ZIP is 89118. The named property is south of Hacienda and west of Rainbow, inside the owner-defined delivery area. Current county address and all 23 building footprints are tied to the retained historical property polygon; its geographic boundary is used only for this named exception. Historical county unit numbers are not imported as current unit identities.');}
 else if(a.startsWith('OUT:')){category='outOfScope';candidateName=a.slice(4)==='gallery'?'Gallery':'Spanish Wells';communityID=null;notes.push('Actual saved-polygon intersection check finds no overlap or boundary contact with either requested county ZIP. The old GILIS20 ZIP label alone cannot establish present geographic scope.');}
 else if(a.startsWith('UNKNOWN:')){category='unknownZIPConflict';candidateName='Revel Vegas';communityID=null;notes.push('Current official contact page says 89148; county polygon and some directories place site in 89147. Remains an unresolved candidate, excluded from verified inventory pending authoritative ZIP reconciliation.');}
 const evidence=[{title:'Current county ZIP boundary polygons',url:zips.url,retrievedAt:zips.retrievedAt,finding:'Independent ZIP polygons compared with the saved candidate geographic extent. Actual candidate polygon intersects '+(scopeCountyZIPs.join(', ')||'neither requested ZIP (including boundary contact)')+'.'},{title:'Saved GILIS20 candidate attributes',url:old.url,retrievedAt:old.retrievedAt,finding:'Historical APN '+apn+'; ZIP '+f.attributes.ZIP+'; AOCAP '+f.attributes.AOCAP+'; RES_TYPE '+f.attributes.RES_TYPE},{title:'County GILIS20 polygon',url:polygons.url,retrievedAt:polygons.retrievedAt,finding:'Geographic extent of the exact saved candidate; scope uses polygon intersection rather than its bounding-box center; never a delivery pin.'},{title:'Current assessor identity/land use',url:lookup.url,retrievedAt:p.retrievedAt,finding:lookup.address?lookup.address+'; '+lookup.description+'; '+lookup.landUse:'Aggregate APN and first two unit-record probes return no populated identity. Alternative evidence follows.'}];
 if(apn==='16327412000'||apn==='16327811000'||apn==='16327710000'){const pdf=apn.slice(0,6);evidence.push({title:'County cadastral map identity',url:'https://maps.clarkcountynv.gov/assessor/parcelmap/mapfiles/map'+pdf+'.pdf',retrievedAt:polygons.retrievedAt,finding:apn==='16327710000'?'Printed SPANISH WELLS label in block710.':'Printed SPANISH RIDGE CONDOMINIUMS label in the candidate block. 163274 block412 visually inspected; 163278 map and existing official community reference agree.'});}
 if(apn==='16327710000'){const ex=joinRaw.areaException;evidence.push({title:'Official community address and postal ZIP',url:ex.officialIdentity.url,retrievedAt:ex.officialIdentity.retrievedAt,finding:ex.officialIdentity.publishedAddress+', Las Vegas NV '+ex.postalZIP+'.'});evidence.push({title:'Current county address and building footprints',url:ex.currentCountyProperty.queryURLs.find(u=>u.includes('strno%3D5355')),retrievedAt:ex.currentCountyProperty.retrievedAt,finding:'APN '+ex.currentCountyProperty.apn+'; exact street address and Spanish Wells legal name; all 23 building footprints fall inside the retained property polygon.'});}
 if(['16331516000','16331813000','16332811000'].includes(apn)){const m=mapped.find(m=>m.communityID===communityID);evidence.push({title:'Existing official geographic unit layer',url:m.maps[0].mapURL,retrievedAt:m.retrievedAt,finding:'Imported named-community unit positions directly overlap this historical county parcel polygon.'});}
 if(category==='unknownZIPConflict')evidence.push({title:'Revel official contact page',url:'https://revelcommunities.com/communities/vegas/contact-us/',retrievedAt:polygons.retrievedAt,finding:'4940 S Conquistador Street, Las Vegas NV 89148; conflicts with county polygon.'});
 if(communityID==='ely-gramercy')notes.push('County building address 9255 differs from official leasing address 9265; use official map overlap and The Gramercy legal identity, not address equality.');
 if(scopeCountyZIPs.length&&!scopeCountyZIPs.includes(String(f.attributes.ZIP)))notes.push('Historical ZIP differs from current county polygon reference; the community can span boundaries.');
 const joinBasis=communityID?deriveJoinBasis(apn,identities.find(c=>c.id===communityID),joinRaw):null;
 if(communityID&&!joinBasis)throw Error('No supported join basis for '+apn+' -> '+communityID);
 if(joinBasis){for(const url of [joinBasis.sourceURL,joinBasis.mapURL,joinBasis.apiURL,joinBasis.identitySourceURL,joinBasis.boundarySourceURL].filter(Boolean))if(!evidence.some(e=>e.url===url))evidence.push({title:'Validated join source: '+joinBasis.type,url,retrievedAt:polygons.retrievedAt,finding:'Join recomputed from retained raw address, geometry or exact subdivision identity; target '+communityID+'.'});}
 records.push({joinBasis,candidateAPN:apn,category,communityID,candidateName,historical:f.attributes,current:{address:lookup.address,description:lookup.description,landUse:lookup.landUse},scopeCountyZIPs,evidence,notes});
}
const errors=validateCountyReconciliation({records},joinRaw);if(errors.length)throw Error(errors.join('\n'));
const summary=Object.fromEntries([...new Set(records.map(r=>r.category))].map(k=>[k,records.filter(r=>r.category===k).length]));
await writeFile('research/geography/county-reconciliation.json',JSON.stringify({scope:'Exactly the 73 saved GILIS20 records; no claim of a complete 2026 census.',generatedAt:new Date().toISOString(),summary,records},null,2)+'\n');console.log(summary);
const lines=['# Reconciliation of the 73 saved county candidates','','Every saved candidate is explicitly adjudicated below. Current assessor facts are retained without owner data. No record is labeled demolished without demolition evidence. Historical AOCAP includes non-residential units and is not an apartment count.','',...Object.entries(summary).map(([k,v])=>'- '+k+': '+v),'','Three previously added residential communities are inventory-only. Spanish Wells is a bounded delivery-area exception with postal ZIP 89118; Revel remains an unresolved ZIP conflict. “Matched legal alias” includes a legal subdivision name differing from the marketed name; it does not establish a date or act of renaming.',''];
for(const r of records)lines.push('## '+r.candidateAPN+' — '+r.category,'',r.communityID?'Inventory ID: '+r.communityID:r.candidateName||'Non-residential',r.joinBasis?'Join basis: '+r.joinBasis.type:'No verified inventory assignment.',r.current.address?`\nCurrent county address: ${r.current.address}. ${r.current.description}. ${r.current.landUse}.`:'',...r.evidence.map(e=>`- [${e.title}](${e.url}) — ${e.finding}`),...r.notes.map(n=>'- '+n),'');
await writeFile('research/COUNTY_RECONCILIATION.md',lines.map(s=>s.trimEnd()).join('\n'));
