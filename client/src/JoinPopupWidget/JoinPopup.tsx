import * as React from 'react';
import * as R from 'ramda';

import { Comp } from '../Utils';

import styles from './JoinPopup.scss';
import '../assets/back.png';

const error: (e:string) => React.ReactElement<any> = 
  R.ifElse(R.compose(R.not, R.either(R.isNil, R.isEmpty)),
    x => <div className="error">{x}</div>,
    _ => <React.Fragment />
  );

const joinAsPlayer: (f: Function) => (t: string) => React.ReactElement<any> = f => R.ifElse(R.equals('notready'),
  _ => <div className="button" onClick={f('player')}>Join as Player</div>,
  _ => <React.Fragment />
);

export const JoinPopup = (props:{close: (e:React.MouseEvent<HTMLDivElement>) => any, 
                                 join: (r:string) => (e:React.MouseEvent<HTMLDivElement>) => any, 
                                 changeName: (e:React.FormEvent<HTMLInputElement>) => any, 
                                 changeMessage: (e:React.FormEvent<HTMLTextAreaElement>) => any, 
                                 name: string, 
                                 message: string,
                                 turn: string,
                                 error: string}) => 
  <div className={styles.JoinPopup}>
    <div className="box">
      <div className="back" onClick={props.close}></div>
      <h3>Join a game</h3>
      <div className="block">
        <input className="name" placeholder="Your name" value={props.name} onChange={props.changeName} required/>
      </div>
      <div className="block">
        <textarea className="message" placeholder="Your message" value={props.message} 
                  onChange={props.changeMessage} required/>
      </div>
      <div className="block">
        {Comp(error).fold(props.error)}
        {Comp(joinAsPlayer(props.join)).fold(props.turn)}
        <div className="button" onClick={props.join('guest')}>Join as Guest</div>
      </div>
    </div>
  </div>
