// ERP owns the public renderer. Packaged/legacy POS snapshots are reproducible.
import {readFile,writeFile} from 'node:fs/promises';
const source=new URL('../../chimera/public/customer-display/index.html',import.meta.url);
const target=new URL('../assets/customer-display/index.html',import.meta.url);
const content=await readFile(source,'utf8');
if(process.argv.includes('--check')){
 if(content!==await readFile(target,'utf8'))throw Error('Run node tool/sync_customer_page.mjs before packaging Companion.');
 console.log('Customer page snapshot matches ERP.');
}else{await writeFile(target,content);await writeFile(new URL('../../chimera-pos/public/customer-display/index.html',import.meta.url),content);console.log('Updated packaged and legacy POS customer pages from ERP.');}
