import {Socket} from "/vendor/phoenix/phoenix.mjs";
import {LiveSocket} from "/vendor/liveview/phoenix_live_view.esm.js";

const colors = ["#5bd5c2", "#79a9ef", "#eba970"];
const Warehouse = {
  mounted() {
    this.canvas = this.el.querySelector("canvas");
    this.ctx = this.canvas.getContext("2d");
    this.robots = new Map(); this.selected = 1; this.trails = true;
    this.zoom = 1; this.pan = {x:0,y:0}; this.frameAt = performance.now();
    this.resize = () => {const r=this.el.getBoundingClientRect();this.width=r.width;this.height=r.height;const d=Math.min(devicePixelRatio,2);this.canvas.width=r.width*d;this.canvas.height=r.height*d;this.ctx.setTransform(d,0,0,d,0,0);};
    this.observer = new ResizeObserver(this.resize); this.observer.observe(this.el);
    this.handleEvent("fleet-frame", ({robots, selected}) => {
      const now=performance.now(); this.selected=selected;
      for(const [id,x,y,owner,online,paused,cargo] of robots){
        const old=this.robots.get(id);
        const current=old?this.position(old,now):{x,y};
        const history=old?.history||[];
        if(online&&(!old||Math.hypot(x-old.x,y-old.y)>.1)){history.push({x,y});if(history.length>12)history.shift();}
        this.robots.set(id,{id,x,y,from:current,at:now,owner,online,paused,cargo,history});
      }
      this.el.querySelector("#map-offline").hidden = robots.length===0 || robots.some(r=>r[4]);
    });
    this.wheel = e => {e.preventDefault();this.zoom=Math.max(.7,Math.min(4,this.zoom*(e.deltaY<0?1.12:.89)));};
    this.down = e => {this.drag={x:e.clientX,y:e.clientY,px:this.pan.x,py:this.pan.y};this.canvas.setPointerCapture(e.pointerId);};
    this.move = e => {if(this.drag){this.pan={x:this.drag.px+e.clientX-this.drag.x,y:this.drag.py+e.clientY-this.drag.y};}};
    this.up = e => {
      if(this.drag&&Math.hypot(e.clientX-this.drag.x,e.clientY-this.drag.y)<6){
        const bounds=this.canvas.getBoundingClientRect(),mx=e.clientX-bounds.left,my=e.clientY-bounds.top;
        let best=null, distance=18;
        for(const robot of this.robots.values()){const p=this.screen(this.position(robot,performance.now()));const d=Math.hypot(p.x-mx,p.y-my);if(d<distance){distance=d;best=robot;}}
        if(best)this.pushEvent("select",{id:best.id});
      }this.drag=null;
    };
    this.canvas.addEventListener("wheel",this.wheel,{passive:false});this.canvas.addEventListener("pointerdown",this.down);this.canvas.addEventListener("pointermove",this.move);this.canvas.addEventListener("pointerup",this.up);
    this.resetButton=document.getElementById("reset-map");this.trailButton=document.getElementById("toggle-trails");
    this.reset=()=>{this.zoom=1;this.pan={x:0,y:0};};this.toggle=()=>{this.trails=!this.trails;this.trailButton.style.color=this.trails?"#b9ee76":"";};
    this.resetButton.addEventListener("click",this.reset);this.trailButton.addEventListener("click",this.toggle);
    this.tick = now => {this.draw(now);this.animation=requestAnimationFrame(this.tick);};this.animation=requestAnimationFrame(this.tick);
  },
  destroyed(){cancelAnimationFrame(this.animation);this.observer.disconnect();this.canvas.removeEventListener("wheel",this.wheel);this.canvas.removeEventListener("pointerdown",this.down);this.canvas.removeEventListener("pointermove",this.move);this.canvas.removeEventListener("pointerup",this.up);this.resetButton.removeEventListener("click",this.reset);this.trailButton.removeEventListener("click",this.toggle);},
  position(r, now){const t=r.online?Math.min(1,(now-r.at)/200):1;return {x:r.from.x+(r.x-r.from.x)*t,y:r.from.y+(r.y-r.from.y)*t};},
  screen(p){const s=Math.min((this.width-70)/100,(this.height-76)/64)*this.zoom;return {x:this.width/2+(p.x-50)*s+this.pan.x,y:this.height/2+(p.y-32)*s+this.pan.y};},
  draw(now){
    if(!this.width)return;
    const c=this.ctx,w=this.width,h=this.height;
    c.clearRect(0,0,w,h);
    const unit=this.screen({x:1,y:0}).x-this.screen({x:0,y:0}).x;
    const box=(x,y,bw,bh,fill,stroke)=>{const p=this.screen({x,y});c.fillStyle=fill;c.fillRect(p.x,p.y,bw*unit,bh*unit);if(stroke){c.strokeStyle=stroke;c.lineWidth=.6;c.strokeRect(p.x,p.y,bw*unit,bh*unit);}};
    box(3,3,94,58,"#111c20","#2a3c40");
    c.strokeStyle="#1a2b30";c.lineWidth=.5;
    for(let x=4;x<=96;x+=4){const a=this.screen({x,y:3}),b=this.screen({x,y:61});c.beginPath();c.moveTo(a.x,a.y);c.lineTo(b.x,b.y);c.stroke();}
    for(let y=4;y<=60;y+=4){const a=this.screen({x:3,y}),b=this.screen({x:97,y});c.beginPath();c.moveTo(a.x,a.y);c.lineTo(b.x,b.y);c.stroke();}
    box(9.5,5,5,54,"#1b2b2c");box(85.5,5,5,54,"#1b2b2c");
    for(let row=0;row<6;row++)for(let col=0;col<6;col++){
      const x=20+col*10,y=10+row*8;
      box(x,y,7.3,4,"#213239","#36505a");
      c.strokeStyle="#2d454d";const a=this.screen({x:x+3.65,y}),b=this.screen({x:x+3.65,y:y+4});c.beginPath();c.moveTo(a.x,a.y);c.lineTo(b.x,b.y);c.stroke();
      if(unit>5){c.fillStyle="#60797e";c.font="8px monospace";const p=this.screen({x:x+1,y:y+2.5});c.fillText(`${String.fromCharCode(65+row)}${col+1}`,p.x,p.y);}
    }
    for(let row=0;row<7;row++){box(4.5,6+row*8,3,4,"#294138","#4b6b55");box(93,6+row*8,3,4,"#313940","#546471");}
    c.font="9px monospace";c.textAlign="center";c.fillStyle="#87a69a";let p=this.screen({x:7,y:1});c.fillText("INBOUND",p.x,p.y);p=this.screen({x:94,y:1});c.fillStyle="#8b9cac";c.fillText("OUTBOUND",p.x,p.y);p=this.screen({x:50,y:63});c.fillStyle="#4e6d75";c.fillText("FULFILLMENT FLOOR / DURABLE PROCESS FIELD",p.x,p.y);c.textAlign="left";
    const size=this.robots.size>1200?1.6:2.6;
    for(const r of this.robots.values()){
      const color=r.online?colors[r.owner%3]:"#5b676e";
      if(this.trails&&r.online&&(this.robots.size<1200||r.id===this.selected)&&r.history.length>1){c.strokeStyle=color;c.globalAlpha=.18;c.lineWidth=1;c.beginPath();r.history.forEach((pt,i)=>{const q=this.screen(pt);i?c.lineTo(q.x,q.y):c.moveTo(q.x,q.y);});c.stroke();c.globalAlpha=1;}
      const q=this.screen(this.position(r,now));
      c.fillStyle=color;c.globalAlpha=r.online?1:.4;
      if(r.cargo){c.fillRect(q.x-size,q.y-size,size*2,size*2);}else{c.beginPath();c.arc(q.x,q.y,size,0,Math.PI*2);c.fill();}
      if(r.paused){c.strokeStyle=color;c.lineWidth=1;c.strokeRect(q.x-4,q.y-4,8,8);}
      c.globalAlpha=1;
      if(r.id===this.selected){c.strokeStyle="#b9ee76";c.lineWidth=1.4;c.beginPath();c.arc(q.x,q.y,9+Math.sin(now/400),0,Math.PI*2);c.stroke();c.fillStyle="#b9ee76";c.font="10px monospace";c.fillText(`R-${String(r.id).padStart(4,"0")}`,q.x+13,q.y-9);}
    }
  }
};
const csrfToken=document.querySelector('meta[name="csrf-token"]').getAttribute("content");
const liveSocket=new LiveSocket("/live",Socket,{params:{_csrf_token:csrfToken},hooks:{Warehouse}});
liveSocket.connect();
window.liveSocket=liveSocket;
