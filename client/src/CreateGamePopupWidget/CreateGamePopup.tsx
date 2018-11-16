import * as React from 'react';
import * as R from 'ramda';

import { Comp } from '../Utils';

import styles from './CreateGamePopup.scss';

const error: (e:string) => React.ReactElement<any> = 
  R.ifElse(R.compose(R.not, R.either(R.isNil, R.isEmpty)),
    x => <div className="error">{x}</div>,
    _ => <React.Fragment />
  );

export const CreateGamePopup = (props:{close: (e:React.MouseEvent<HTMLDivElement>) => any,
                                       create: (e:React.MouseEvent<HTMLDivElement>) => any,
                                       changeName: (e:React.FormEvent<HTMLInputElement>) => any,
                                       changeMessage: (e:React.FormEvent<HTMLTextAreaElement>) => any,
                                       name: string,
                                       message: string,
                                       error: string}) => 
  <div className={styles.CreateGamePopup}>
    <div className="box">
      <div className="back" onClick={props.close}>Back</div>
      <input className="name" placeholder="Your name" value={props.name} onChange={props.changeName} required/><br/>
      <textarea className="message" placeholder="Your message" value={props.message} onChange={props.changeMessage} required/><br/>
      {Comp(error).fold(props.error)}
      <div className="button" onClick={props.create}>Create a game</div>
    </div>
  </div>
